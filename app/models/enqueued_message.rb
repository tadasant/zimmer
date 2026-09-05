class EnqueuedMessage < ApplicationRecord
  # The statuses a queued message can hold.
  #
  # `pending` -> `processing` -> `sent` is the delivery path, and the row is
  # destroyed immediately after `sent` — so `sent` is a moment, not a resting
  # place. `undelivered` is the one terminal resting state, and two things put a
  # row there: the session was archived while this message was still queued,
  # which ends every path by which it could have been delivered; or #stale? found
  # the state the message reports had moved on before anybody read it, which
  # leaves nothing worth delivering.
  STATUSES = %w[pending processing sent undelivered].freeze

  # Who wrote the message.
  #
  # `caller` is everything queued on someone's behalf, and that is most of the
  # queue: the web form, the two REST endpoints, MCP `manage_enqueued_messages`
  # and `action_session`, a trigger's follow-up, the GitHub comment poller. All
  # of them relay something somebody else said. The `automated_*` origins are
  # the notices Zimmer addresses to a session on its own behalf: the two
  # AutomatedSessionMessage writes when a poller sees GitHub move, and the
  # recovery nudge SpotSessionHold parks in the queue when the gate refuses the
  # turn that was carrying it.
  #
  # The distinction is not bookkeeping. It is what lets a reader of a retired
  # queue — on the session page, the REST index, the MCP list — tell a message
  # somebody is waiting on from one Zimmer wrote to itself.
  ORIGINS = %w[caller automated_pr_merged automated_merge_conflict automated_recovery_nudge].freeze

  # The origins whose message Zimmer addressed to the session itself, and which
  # an archive therefore answers rather than discards.
  #
  # There is exactly one, and the bar for a second is high: the message has to
  # carry nothing that is still true once the session is archived. The recovery
  # nudge qualifies because its entire content is "you may have been interrupted
  # — continue if you were mid-task, otherwise keep waiting". Delivered to an
  # archived session, which is neither, it is a question with no answer. Nobody
  # wrote it, nobody is waiting on a reply, and no reader is left to discover the
  # loss from.
  #
  # `automated_pr_merged` deliberately does NOT qualify, and that contrast is the
  # design rather than an omission. A merge is a fact about the world that
  # outlives the archive, and an UNFORCED strand of that notice is how the
  # mis-credited-PR bug behind #555 was found — a status-summary fork that
  # inherited its source's PR, had the merge notice queued onto it, and was
  # archived by the harvest job. Exempting it would silence the alert's own smoke
  # detector. Same for `automated_merge_conflict`: an unresolved conflict is
  # still unresolved afterwards and nothing else reports it.
  #
  # `AutomatedPrompts::HEARTBEAT` is the honest near-miss, and it is left OUT
  # deliberately rather than by oversight. It reaches the same queue by the same
  # route — HeartbeatSweepJob -> deliver_follow_up! -> a refused spot turn -> the
  # durable queue — and on the criterion above it would qualify: Zimmer writes it,
  # and "keep working toward the goal, or turn the heartbeat off" is not still
  # true once the session is archived. What it does not have is an observed page.
  # Every origin added here is a permanent narrowing of the one alert that reports
  # a message being thrown away, so the bar for widening it is a firing this
  # exemption would have prevented, not an argument that it would fit. Add the
  # heartbeat when it pages, and not before.
  SELF_ADDRESSED_ORIGINS = %w[automated_recovery_nudge].freeze

  # The origins whose message names a GitHub state that can un-happen between
  # the poll that noticed it and the session's next turn boundary, and which is
  # therefore re-read before delivery. See #stale?.
  #
  # `automated_merge_conflict` is the whole list, and `automated_pr_merged` is
  # deliberately not on it: a merge is a fact that outlives the poll, so there
  # is nothing to re-check. Only conflicts un-resolve — a session that rebases,
  # resolves and force-pushes in the minutes after the poll makes the notice
  # false before anybody reads it (tadasant/zimmer#835).
  STALENESS_CHECKED_ORIGINS = %w[automated_merge_conflict].freeze

  belongs_to :session

  # Validations
  validates :content, presence: true, length: { maximum: Session::PROMPT_MAX_LENGTH, message: "is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)" }
  validates :goal, length: { maximum: Session::GOAL_MAX_LENGTH, message: "is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters)" }, allow_nil: true
  validates :position, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :status, inclusion: { in: STATUSES, message: "%{value} is not a valid status" }
  validates :origin, inclusion: { in: ORIGINS, message: "%{value} is not a valid origin" }

  # The other end of the invariant EnqueuedMessageDrainJob enforces on `pause`.
  #
  # That callback catches a message that arrives before the session comes to
  # rest. This one catches a message that arrives after it already has. None of
  # the three `create` surfaces — the web queue form, `POST
  # /api/v1/sessions/:id/enqueued_messages`, MCP `manage_enqueued_messages` —
  # checks the session's state, and all three tell the caller the message will
  # be delivered "when the session becomes idle". A session at rest already is,
  # and nothing was going to come back for the row: the only sweep that wakes an
  # idle session, HeartbeatSweepJob, skips one that has a pending message.
  #
  # "At rest" is Session#idle_for_queued_delivery?, which is BOTH resting states.
  # It used to be `needs_input?` alone, and `waiting` — the state an `open-pr`
  # self-wake, an `action_session sleep` and every park leave behind — had no
  # drain trigger whatsoever. That is the gap in #566: a PR-merged notice was
  # queued onto a session resting in `waiting`, nothing was scheduled to deliver
  # it, and it was still `pending` when the archive guard named it five hours
  # later.
  #
  # after_create_commit, not after_create: the job must not run against a row
  # its own transaction has not committed yet.
  after_create_commit :deliver_if_session_already_idle

  # Scopes
  scope :pending, -> { where(status: "pending") }
  scope :undelivered, -> { where(status: "undelivered") }
  scope :ordered, -> { order(position: :asc) }
  scope :staleness_checked, -> { where(origin: STALENESS_CHECKED_ORIGINS) }

  # Mark message as sent
  def mark_as_sent!
    update!(status: "sent")
  end

  # Retire a message that will never be delivered.
  #
  # Called from the `archive` transition, which is the point at which delivery
  # becomes impossible. (The other producer of `undelivered`, #retire_as_stale!,
  # writes the status conditionally rather than through here — see there.)
  # Session#process_next_enqueued_message! only claims
  # `pending` rows, and the only caller that claims them for a live session is
  # AgentSessionJob's end-of-turn drain, which an archived session never
  # reaches. Leaving the row `pending` after that is what made the loss silent —
  # every reader of the queue (the panel, the REST index, the MCP list) treats
  # `pending` as "still going to be sent".
  #
  # The row is kept rather than destroyed. Its content is the thing the sender
  # was promised delivery of, so it stays readable through the same surfaces
  # that reported it queued.
  def mark_undelivered!
    update!(status: "undelivered")
  end

  # Whether this is a message Zimmer wrote to the session rather than one it
  # accepted on somebody's behalf, and so whether an archive that discards it
  # has lost anything. See SELF_ADDRESSED_ORIGINS for why the list is one entry
  # long and why `automated_pr_merged` is not on it.
  #
  # Read by the strand alert only. Every other reader of a retired queue shows
  # the row whatever its origin, because "what was in the queue" is a different
  # question from "was anything lost".
  def self_addressed?
    SELF_ADDRESSED_ORIGINS.include?(origin)
  end

  # Whether the thing this message is about has stopped being true, so that
  # delivering it would cost the session a turn to tell it nothing.
  #
  # The same question AoEventSubject asks of an event's subject before firing a
  # condition, asked at the other end of the same kind of gap. A poller reads
  # GitHub, finds a conflict, and — because the session is mid-turn or asleep
  # rather than parked in `needs_input` — queues the notice instead of sending
  # it. The row then sits until the session's next turn boundary, which is
  # minutes away, and in those minutes the session may well have rebased,
  # resolved and force-pushed. That is exactly what happened in
  # tadasant/zimmer#835: the notice arrived roughly six minutes after the poll
  # that wrote it and five after the conflicts were gone.
  #
  # Why it matters more than the wasted turn: a resume consumes a session's
  # one-time wake triggers. The `open-pr` skill's terminal step has a session
  # schedule a bounded self-wake and end its turn in `waiting` so it sleeps on
  # its PR rather than sitting in the human's action queue. A stale notice
  # destroys that wake, and a session that takes the notice at face value —
  # finds nothing to resolve, ends its turn — is then left with no pending
  # trigger and no running turn: invisible until a human types into it.
  #
  # Fails OPEN, on every path. An unreadable, timed-out or still-computing
  # mergeability read answers `false`, so the message is delivered. Suppressing
  # a genuine conflict notice is the strictly worse failure — the session sleeps
  # on a PR that will never merge and nothing says why — and this method's job
  # is to drop only what it can positively show is moot.
  #
  # The readings that make a queued conflict notice moot. `:mergeable` is the
  # case the guard exists for; `:not_open` is the PR having merged or closed
  # while the notice sat in the queue, which is just as positively known and
  # just as pointless to wake a session about. Every other reading — including
  # `:unknown` — delivers.
  DELIVERY_SUPPRESSING_READINGS = %i[mergeable not_open].freeze

  # @return [Boolean]
  def stale?
    return false unless STALENESS_CHECKED_ORIGINS.include?(origin)

    pr_url = AutomatedPrompts.merge_conflict_pr_url(content)
    if pr_url.blank?
      Rails.logger.warn(
        "[EnqueuedMessage] Message #{id} (session ##{session_id}) has origin #{origin} but names no PR — delivering"
      )
      return false
    end

    reading = GithubPullRequestMergeability.read(pr_url)
    suppress = DELIVERY_SUPPRESSING_READINGS.include?(reading)

    # Logged at info on every branch, not just the suppression: the point of
    # this line is that a human reading a session that never got a conflict
    # notice can tell "suppressed because the PR was clean" from "the notice was
    # never sent at all".
    Rails.logger.info(
      "[EnqueuedMessage] Re-read #{pr_url} before delivering message #{id} to session ##{session_id}: " \
      "read #{reading} — #{suppress ? 'suppressing the conflict notice' : 'delivering'}"
    )

    suppress
  end

  # Retire this message because #stale? found the state it reports has moved on.
  #
  # `undelivered` rather than a destroy, for the reason the archive path keeps
  # its rows: the content stays readable through every surface that reported the
  # message queued — the session panel, the REST index, MCP
  # `manage_enqueued_messages` — so "suppressed because the PR was clean" is a
  # thing a human can see rather than infer from an absence. Position is left
  # alone for the same reason it is on the archive path: a retired row holds its
  # position, and only a delivery renumbers the queue behind it.
  #
  # Conditional on the row still being `pending`, and a bulk `update_all` for
  # that reason rather than `mark_undelivered!`: a peer that claimed it first
  # (FOR UPDATE SKIP LOCKED, in Session#process_next_enqueued_message!) owns it,
  # and taking it out from under that peer would strand a message already being
  # delivered.
  #
  # @return [Boolean] true if this call is the one that retired the row
  def retire_as_stale!
    retired = self.class.where(id: id, status: "pending")
                  .update_all(status: "undelivered", updated_at: Time.current) == 1
    return false unless retired

    forget_poller_conflict_markers
    true
  end

  # Reorder message to a new position
  # Updates positions of other messages in the same session to maintain sequential ordering
  # Uses a temporary position (0) to avoid unique constraint violations during swap
  #
  # Unlike the bulk decrement on the DELETE paths, this method does not rely on
  # the query planner, or on the deferred unique constraint: it parks the moving
  # row at 0, then shifts its neighbours one row per statement in an order Ruby
  # pins explicitly (ascending when moving down, descending when moving up), so
  # every write lands on a position no row still holds.
  def reorder_to(new_position)
    return if new_position == position

    transaction do
      old_position = position

      # Move current message to temporary position (0) to avoid unique constraint violation
      update_column(:position, 0)

      if new_position > old_position
        # Moving down: shift messages between old and new position up
        session.enqueued_messages
               .where("position > ? AND position <= ?", old_position, new_position)
               .order(position: :asc)
               .each { |msg| msg.update_column(:position, msg.position - 1) }
      else
        # Moving up: shift messages between new and old position down
        session.enqueued_messages
               .where("position >= ? AND position < ?", new_position, old_position)
               .order(position: :desc)
               .each { |msg| msg.update_column(:position, msg.position + 1) }
      end

      # Move to final position
      update_column(:position, new_position)
    end
  end

  private

  # Hand the PR this notice named back to the poller's debounce, so a conflict
  # that turns out to have been real is re-confirmed rather than silently
  # swallowed. GitHubMergeConflictPollerJob.forget_conflict! carries the full
  # reasoning; the short version is that the poller has already marked this PR
  # "confirmed + notified", and that marker is cleared only by a clean reading.
  #
  # Best-effort on purpose. The retirement has already committed and is the
  # thing that had to happen; failing to reset the debounce is a missed
  # re-notification, not a lost message, and raising here would turn it into
  # one. It is logged loudly instead.
  def forget_poller_conflict_markers
    pr_url = AutomatedPrompts.merge_conflict_pr_url(content)
    return if pr_url.blank? || session.nil?

    GitHubMergeConflictPollerJob.forget_conflict!(session, pr_url)
  rescue => e
    Rails.logger.error(
      "[EnqueuedMessage] Retired message #{id} as stale but could not reset the conflict debounce for " \
      "session ##{session_id}: #{e.class}: #{e.message} — a genuine conflict on this PR may not be re-reported"
    )
  end

  # See the callback declaration for why this exists. The job re-reads
  # everything itself, so this only has to be cheap and roughly right — and it
  # deliberately does not fire for a `running` session, where the ordinary
  # end-of-turn drain is already the answer. A `waiting` session the job then
  # declines (spot-held, auth-parked, never started) costs one delayed job that
  # logs why and returns; that is the right side to be wrong on, because the
  # other side is a message nobody ever comes back for.
  def deliver_if_session_already_idle
    return unless status == "pending"
    return unless session&.idle_for_queued_delivery?

    EnqueuedMessageDrainJob.set(wait: EnqueuedMessageDrainJob::DELAY).perform_later(session_id)
  rescue => e
    # Log-only, and deliberately not fatal to the create: the caller queued a
    # message and that succeeded. The `pause` callback picks the queue up at the
    # session's next turn boundary either way — this only makes it sooner.
    Rails.logger.error(
      "[EnqueuedMessage] Failed to schedule a drain for idle session #{session_id}: #{e.class}: #{e.message}"
    )
  end
end
