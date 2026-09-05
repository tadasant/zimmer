# frozen_string_literal: true

# Delivers the message a session came to rest on top of.
#
# The invariant this enforces is the idle half of the one
# Sessions::ArchiveGuard enforces for `archive`: a session must not idle with a
# message still queued for it. Where the archive half refuses the transition —
# archiving ends every delivery path, so the only honest answer is not to
# archive — an idle session is recoverable. It is idle, which is exactly the
# condition under which a queued message is supposed to be delivered, so the fix
# is to deliver it and let the session keep running.
#
# "Idle" is BOTH resting states, not just `needs_input`. That was the gap behind
# #566: the three create surfaces all promise the caller delivery "when the
# session becomes idle", and a session resting in `waiting` — asleep on an
# `open-pr` self-wake, slept by `action_session sleep`, dormant after a park —
# already is. Nothing came back for those rows at all. #skip_reason is where the
# populations of `waiting` that genuinely cannot take a message are named.
#
# AgentSessionJob already drains the queue at its four turn-end paths, and does
# it BEFORE `pause!` so the session never flaps running → needs_input → running.
# That is still the hot path and this job is not a replacement for it. This job
# covers what that ordering cannot:
#
#   - The race. The drain reads the queue, finds it empty, and then `pause!`
#     commits. A message enqueued in that window lands `pending` on a session
#     that is already `needs_input`, and nothing ever comes back for it.
#   - Every other way into `needs_input`. The MCP `pause` action, `POST
#     /api/v1/sessions/:id/pause`, the web pause button,
#     Sessions::InterruptService and SessionRecoveryService all call `pause!`
#     directly with no drain of their own.
#   - A message queued onto a session that is already idle. The three `create`
#     surfaces (web, REST, MCP `manage_enqueued_messages`) have no state guard,
#     and they all tell the caller the message "will be delivered when the
#     session becomes idle" — which it already is.
#
# Nothing else would pick these up. HeartbeatSweepJob, the one sweep that wakes
# an idle session, explicitly skips a session with a pending message on the
# assumption that something else is about to deliver it.
class EnqueuedMessageDrainJob < ApplicationJob
  queue_as :default

  # Deliberately NOT good_job_control_concurrency_with. A `total_limit` counts
  # the running job itself, so the retry this job schedules for itself would be
  # the enqueue that gets dropped — silently turning the bounded retry into a
  # single attempt. Duplicate drains are cheap and safe instead: they serialize
  # on the advisory lock, and whichever gets there second finds the queue empty
  # or the session running and returns.

  # How long to let a synchronous caller finish before stepping in.
  #
  # The callers that pause a session and then immediately deliver something to
  # it — Sessions::InterruptService, SessionContinuation's auto-continue,
  # SessionsController#follow_up — are the ones whose intent is most specific,
  # and a drain that beat them to the queue would take the message out from
  # under them. Sessions::InterruptService reports that as a 409 to its caller
  # and MCP's `send_now` then discards a message it was actually going to
  # deliver. The delay costs nothing: this is the corrective path, not the hot
  # one, and a session that is genuinely stuck was going to sit there forever.
  DELAY = 10.seconds

  # How many times to try before giving up and saying so out loud.
  MAX_ATTEMPTS = 3

  # Backoff between attempts. Bounded on purpose: the failure this guards
  # against is a session that cannot take its message at all, and retrying that
  # forever is a spin loop, not a recovery.
  RETRY_DELAY = 30.seconds

  # Where the attempt count lives while a drain is failing. Cleared by `resume`,
  # so a session that gets going again by any route starts fresh.
  ATTEMPTS_KEY = "enqueued_drain_attempts"

  # Deliberately runs in NO transaction of its own, and takes no advisory lock.
  #
  # EnqueuedMessageProcessorService#process_next_message opens its own
  # transaction and rescues everything inside it, and a Rails `transaction`
  # block JOINS an open one rather than nesting under a savepoint. So wrapping
  # this call — in Session.with_session_lock, or in anything else — converts the
  # service's rescue from "roll the claim back and report false" into "swallow
  # the error and let the outer transaction commit whatever got as far as being
  # written". A message claimed and destroyed with no AgentSessionJob behind it
  # is exactly the silent loss this whole invariant exists to stop.
  #
  # Left unwrapped, the service's transaction is the outermost one: a failure
  # mid-delivery rolls the message back to `pending` and returns false, which is
  # what handle_failed_attempt is written against.
  #
  # Concurrency is the service's job and it already does it — the claim is a
  # `FOR UPDATE SKIP LOCKED` on the row plus a `lock!` on the session, so at
  # most one caller can take a given message. AgentSessionJob's end-of-turn
  # drain calls it bare for the same reason. What an advisory lock would have
  # bought is only that Sessions::InterruptService never has to report a
  # 409 because we took the message it was about to deliver, and DELAY is the
  # cheaper way to buy that.
  def perform(session_id)
    session = Session.find_by(id: session_id)
    return unless session

    skip = skip_reason(session)
    if skip
      Rails.logger.info("[EnqueuedMessageDrainJob] Session #{session_id}: nothing to do (#{skip})")
      return
    end

    attempt = record_attempt(session)

    if EnqueuedMessageProcessorService.new(session, broadcast_service: BroadcastService.new).process_next_message
      session.logs.create!(
        content: "Queued message delivered — session resumed rather than idling with it undelivered",
        level: "info"
      )
      Rails.logger.info("[EnqueuedMessageDrainJob] Session #{session_id}: delivered a queued message")
      return
    end

    # The queue emptying without a delivery is a success, not the failure
    # handle_failed_attempt is written against. EnqueuedMessageProcessorService
    # retires a stale notice — one whose state moved on while it sat here, see
    # EnqueuedMessage#stale? — and then has nothing left to claim, which is
    # exactly the outcome wanted. A peer draining the queue between skip_reason
    # and here lands in the same branch, and is equally not a failure.
    unless session.enqueued_messages.pending.exists?
      # Give the attempt back. record_attempt runs before the try, and the
      # counter is otherwise cleared only by the `resume` transition — which a
      # retire-only drain never reaches. Left standing, three of these would
      # leave the counter at MAX_ATTEMPTS and send the NEXT genuine delivery
      # failure straight to give_up with no retries and a page.
      clear_attempts(session)
      Rails.logger.info(
        "[EnqueuedMessageDrainJob] Session #{session_id}: queue emptied without a delivery " \
        "(retired or taken by a peer) — nothing left to deliver"
      )
      return
    end

    handle_failed_attempt(session, attempt)
  end

  private

  # Why this session should be left alone, or nil to go ahead.
  #
  # Every one of these is a state in which the session genuinely cannot take a
  # message right now, not a preference. Delivering anyway would either spawn a
  # second agent process against one clone or re-run the session straight back
  # into the wall it just hit.
  def skip_reason(session)
    return "no longer idle (#{session.status})" unless session.idle_for_queued_delivery?
    return "queue is empty" unless session.enqueued_messages.pending.exists?

    # Everything from here to the `nil` is about a session resting in `waiting`
    # rather than `needs_input`. `needs_input` has exactly one meaning — the turn
    # ended and nobody is coming — while `waiting` is the resting state Zimmer
    # puts a session in for four different reasons, and three of them are "asleep
    # on purpose, with something already scheduled to wake it". Handing a message
    # to one of those is not an early delivery, it is a fight with whatever owns
    # the wake.
    if session.waiting?
      dormant = dormant_by_design_reason(session)
      return dormant if dormant
    end

    # The agent process is STILL RUNNING and blocked on a synchronous MCP
    # elicitation. Resuming would spawn a second process and orphan the
    # round-trip. HeartbeatSweepJob refuses to nudge this state for the same
    # reason; the message is delivered when the elicitation resolves and the
    # resulting turn ends.
    return "blocked on an MCP elicitation" if session.blocked_on_elicitation?

    # Parked by AuthOutageParkService on a quota or auth wall. AgentSessionJob's
    # own end-of-turn drain reads the same marker and skips the handoff for it:
    # a fresh turn would hit the same wall, burn the message, and park again.
    if session.metadata&.dig("auth_outage_reason").present?
      return "parked on an auth or quota outage"
    end

    # AgentSessionJob has already scheduled a retry carrying the original
    # prompt. Delivering the queued message now would race that retry into the
    # same failing MCP server.
    if session.metadata&.dig("paused_by") == "mcp_retry"
      return "waiting on a scheduled MCP connection retry"
    end

    # `paused_by: "user"` is deliberately NOT on this list, and the omission is
    # the one judgement call in here worth stating out loud.
    #
    # The recovery sweeps do exempt it — `refresh_all` will not auto-continue a
    # session a human paused — but they are answering a different question.
    # There, resuming means Zimmer deciding on its own to restart work the human
    # stopped. Here there is queued input: someone was told their message would
    # be delivered, and pausing the current turn is not the same as withdrawing
    # the next one. The invariant was stated without an exception, so this has
    # none; a caller who wants the message gone deletes it.
    nil
  end

  # Why a `waiting` session is asleep on purpose, or nil when it is merely idle.
  #
  # `needs_input` never reaches here: it has one meaning and this job is the
  # answer to it. `waiting` is the overloaded one.
  #
  # NOT on this list, deliberately: a session dormant on its own armed wake-up
  # (`paused_until_scheduled_time?`). That is the case this whole issue is about
  # — the `open-pr` skill has a session sleep on a bounded self-wake so it does
  # not occupy the human's action queue while its PR is rated, and the merged-PR
  # notice is queued rather than sent precisely because the session is `waiting`
  # rather than `needs_input`. The notice IS what that session is asleep waiting
  # for, so consuming the wake to deliver it is the point, not a cost.
  # EnqueuedMessage#stale? is what keeps that honest: a notice whose subject has
  # moved on is retired rather than delivered, so a wake is only ever spent on a
  # message that still says something.
  def dormant_by_design_reason(session)
    # A job is already driving it. `waiting` is not only a resting state: it is
    # also where a session sits for the whole of its FIRST START, from the moment
    # AgentSessionJob claims `running_job_id` through the clone, the session-id
    # write and the spawn, until the transition to `running` at the far end. That
    # window is seconds to tens of seconds, and in it the session looks idle by
    # every other test here — it has a session id, it is not held, nothing is
    # parked.
    #
    # Delivering into it loses the message outright rather than merely delivering
    # it early. EnqueuedMessageProcessorService would take its `resume!` branch
    # (the handoff branch, the only one that clears `running_job_id`, is selected
    # by the session already being `running`), claim and destroy the row, and
    # enqueue a fresh AgentSessionJob — which the concurrency guard at the top of
    # #perform then refuses as a duplicate of the live first-start job. Queue
    # empty, no turn behind it, and the drain counts it a success so nothing
    # retries or alerts.
    #
    # Costs nothing on the paths this job is for: `pause` clears the marker
    # through cleanup_running_job, and SpotSessionHold#return_to_queue! and
    # AuthOutageParkService.resume_parked! clear it too, so a session genuinely at
    # rest carries no job id. Deliberately scoped to `waiting` rather than asked
    # of both states — a `needs_input` session with a stale job id is the case
    # this job's whole bounded-retry-and-alert path already exists to report.
    return "a job is already driving it" if session.running_job_id.present?

    # No runtime session id. A follow-up prompt into a session with none is
    # reclassified by AgentSessionJob as a FRESH START, which runs the session's
    # own prompt and DISCARDS the follow-up — so "delivering" here would destroy
    # the message. It drains at the end of that first turn like any other,
    # through AgentSessionJob's ordinary end-of-turn path.
    #
    # `session_id.blank?`, deliberately, and NOT `never_ran?`. The two differ by
    # `transcript.blank?`, and the reclassification this guards against keys on
    # the session id ALONE — so `never_ran?` is the strictly narrower question
    # and it misses the population that matters most: a session that HAS run,
    # and therefore has a transcript, whose stale runtime id was released
    # (AgentSessionJob's failed-resume recovery and
    # ProcessLifecycleManager#release_stale_runtime_session_id! both write
    # `session_id = nil` on a session with a full transcript). Such a session
    # rests in `waiting` looking idle by every other test here, and draining
    # into it spends the message on a turn that runs `session.prompt` instead
    # and throws the message away — while the drain logs a delivery.
    return "has no runtime session id to resume" if session.session_id.blank?

    # Held or paused at the spot quota gate. Delivering would enqueue a turn that
    # SpotSessionHold refuses at the door and re-queues as a fresh row — the
    # message survives, but it churns position and origin on every pass, and the
    # gate's own re-check is already the thing that will run it.
    return "held at the spot quota gate" if SpotSessionHold.held?(session)
    return "paused in the spot queue" if SpotSessionPause.paused?(session)

    nil
  end

  # Undo record_attempt for an outcome that was not an attempt at anything.
  def clear_attempts(session)
    return if session.metadata&.dig(ATTEMPTS_KEY).blank?

    session.remove_metadata!(ATTEMPTS_KEY)
  end

  # Record the attempt BEFORE trying, so an attempt that takes the worker down
  # with it still counts. A counter that only advanced on a clean failure would
  # not bound the case it exists to bound.
  def record_attempt(session)
    attempt = session.metadata&.dig(ATTEMPTS_KEY).to_i + 1
    session.merge_metadata!(ATTEMPTS_KEY => attempt)
    attempt
  end

  # EnqueuedMessageProcessorService returned false with the session still idle
  # and the queue still non-empty — so this is a real failure, not a peer having
  # got there first and not a notice retired as stale. The caller checks the
  # queue again before reaching here, which is what rules those two out.
  def handle_failed_attempt(session, attempt)
    if attempt < MAX_ATTEMPTS
      Rails.logger.warn(
        "[EnqueuedMessageDrainJob] Session #{session.id}: drain attempt #{attempt}/#{MAX_ATTEMPTS} " \
        "failed, retrying in #{RETRY_DELAY.to_i}s"
      )
      self.class.set(wait: RETRY_DELAY).perform_later(session.id)
      return
    end

    give_up(session, attempt)
  end

  # The terminal case, and the reason this job is bounded at all.
  #
  # The messages are deliberately left `pending` rather than retired to
  # `undelivered` the way an archive retires them. `undelivered` means "no path
  # to delivery remains", which is true of an archived session and false of this
  # one: it is idle and reachable, and the next turn anybody gives it drains the
  # queue through AgentSessionJob's normal end-of-turn path. Retiring here would
  # destroy a message that is still deliverable in order to record that we
  # personally could not deliver it.
  #
  # So the loud part is the alert rather than a status change. Something is
  # wrong with this session specifically — it is idle, it has work queued, and
  # three attempts spread over a minute could not hand that work over.
  def give_up(session, attempt)
    count = session.enqueued_messages.pending.count
    Rails.logger.error(
      "[EnqueuedMessageDrainJob] Session #{session.id}: giving up after #{attempt} attempts with " \
      "#{count} message(s) still queued"
    )
    session.logs.create!(
      content: "Could not deliver #{count} queued message(s) after #{attempt} attempts — session is idle " \
               "with them still queued. They stay queued and will be delivered on the next turn.",
      level: "error"
    )

    alert_on_undeliverable_queue(session.id, count, session.status)
  rescue => e
    # This method IS the loud part. It failing silently is the defect again.
    Rails.logger.error(
      "[EnqueuedMessageDrainJob] Failed to report an undeliverable queue for session #{session.id}: " \
      "#{e.class}: #{e.message}"
    )
  end

  # Posted AFTER any open transaction commits, for a sharper version of the reason
  # SessionStateMachine#report_swallowed_side_effect gives: AlertService talks to
  # Slack synchronously (5s connect / 10s read), and this method is reached from
  # give_up, whose caller may be inside EnqueuedMessageProcessorService's
  # transaction on a failed delivery. Alerting inline would pin that transaction —
  # and the `lock!` it holds on this session's row — across a network round trip,
  # blocking any concurrent interrupt on the one session already in trouble.
  # after_all_transactions_commit runs the block immediately when no transaction
  # is open, which is the ordinary case here, so nothing is deferred that does not
  # need to be. (This job opens no transaction and takes no advisory lock of its
  # own — see the class header.)
  def alert_on_undeliverable_queue(session_id, count, status)
    ActiveRecord.after_all_transactions_commit do
      AlertService.raise_alert(
        "Session idle with an undeliverable queued message",
        details: "Session #{session_id} is at rest (#{status}) with #{count} message(s) still queued. " \
                 "#{MAX_ATTEMPTS} attempts to deliver them failed, so the session is sitting idle on work " \
                 "it was given. The messages are still `pending` and will go out on the next turn the " \
                 "session takes — but nothing is going to give it one on its own.\n\n" \
                 "<#{AppUrl.base_url}/sessions/#{session_id}|View session in Zimmer>",
        source: "EnqueuedMessageDrainJob",
        dedup_key: "undeliverable_enqueued_messages_#{session_id}"
      )
    rescue => e
      # The block outlives give_up's own rescue, so it needs its own.
      Rails.logger.error(
        "[EnqueuedMessageDrainJob] Failed to alert on an undeliverable queue for session #{session_id}: " \
        "#{e.class}: #{e.message}"
      )
    end
  end
end
