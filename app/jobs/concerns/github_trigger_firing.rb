# frozen_string_literal: true

# Firing a GitHub trigger condition for one item — everything about a fire that does not depend on
# how the item was found. GithubTriggerPollerJob finds items by searching; GithubEventJob is handed
# one by a webhook delivery. Both render the same prompt (#github_fire_prompt, #context_block,
# Trigger#interpolate_prompt) and spawn through the same Trigger#create_session!, so a session a
# delivery fired is indistinguishable from one the poller fired, fencing included.
#
# Claims. While GitHub's webhook path is switched on, both paths can see the same event — a new
# issue, or a label just added — so a fire claims it for its condition in TriggerEventClaim, inside
# the transaction that spawns the session; the arrangement SlackTriggerFiring#fire_slack_event uses.
# The path that loses the claim fires nothing and reports the event as fired, so the poller records
# it and moves its state on. With GitHub on `poll` nothing claims and #fire runs exactly as the
# poller always has.
#
# The two condition types differ only in the key, and therefore in the claim's lifetime.
# `github_issue` claims `github:<repo>#<n>:opened`, an event that cannot recur, and expires on
# TriggerEventClaim::RETENTION. `github_label` claims `github:<repo>#<n>:label:<label>`, an event
# that CAN recur — a label comes off and goes back on — so its claim is released the tick the poller
# drops the same item from its seen-set (GithubTriggerPollerJob#release_label_claims). A claim that
# outlived the seen-set would silently swallow the re-add, which is #647's direction and the worse
# one on the merge gate.
module GithubTriggerFiring
  extend ActiveSupport::Concern
  include GithubTriggerSearch

  # Bodies are pasted into the prompt verbatim. A pathological issue body should not
  # blow out the session's context before the agent has read its instructions.
  MAX_BODY_LENGTH = 10_000

  private

  # Creates the session for one item. Returns true only if a session was created, since
  # the caller uses that to decide whether it may advance its state past this item.
  # +label+ is the label that was added, and is required for a `github_label` condition: it is half
  # of the event's identity, so it is half of the claim key.
  def fire(condition, item, event:, via: "poll", label: nil)
    return fire_claimed(condition, item, event: event, via: via, label: label) if claims_github_event?(via)

    trigger = condition.trigger

    prompt = github_fire_prompt(trigger, item, event: event)

    # Set immediately before the call, and read only in the rescue below.
    # #create_session! clears the trigger's created-session marker on entry, so the
    # marker is a true report of THIS fire — but only once we are inside it. A raise
    # before that (interpolation, the context block) would otherwise read the marker
    # left by the PREVIOUS item in this same tick, and record an item as fired that
    # has no session at all. That is #647's direction, and it is the worse one.
    #
    # Neither caller happens to expose the stale read today: both #record_fired_key and
    # #record_fired_issue reload the condition after every successful fire, and #reload
    # drops the association cache the marker lives on. That is an accident of an
    # unrelated call rather than a property to rely on — the durability floors could
    # move, and a floor whose own reload raised leaves the cache in place — so the guard
    # here is what actually decides it.
    spawn_attempted = true
    session = trigger.create_session!(prompt: prompt)

    # Burst control suppressed the spawn: the trigger has exceeded its cap and is
    # spawning nothing until the burst subsides. Leave the item unseen so it fires
    # for real once the trigger is back under its cap (its label is still there —
    # the seen-set is state, so nothing is lost). This is expected behavior, not a
    # dropped wake, so log it at info rather than storming WARN per item per tick
    # for the whole burst.
    if session.nil? && trigger.last_fire_burst_suppressed?
      Rails.logger.info "#{github_log_tag} Trigger #{trigger.id} is burst-suppressed for " \
                        "#{item_key(item)} (#{event}); leaving it unseen so it fires once the burst ends"
      return false
    end

    # Dedup suppressed the spawn: a session this trigger already spawned is still
    # pending and carries the same intent. Leave the item unseen — unlike a
    # broadcast event, a label or an open issue is durable state, so the item
    # fires for real on a later tick once that session is done. Info, not warn:
    # nothing was dropped and nothing is wrong.
    if session.nil? && trigger.last_fire_skipped_for_pending_session?
      Rails.logger.info "#{github_log_tag} Trigger #{trigger.id} skipped #{item_key(item)} (#{event}) — " \
                        "session #{trigger.last_fire_pending_session.id} is still pending; leaving it unseen"
      return false
    end

    # create_session! returns the session truthily even when a reuse_session trigger DROPPED
    # the follow-up prompt (target session busy, enqueue_messages off). Treating that as a
    # fire would record the item as seen and consume the event without any work ever having
    # been done. AoEventTriggerJob and ScheduleTriggerJob guard the same way.
    if session.nil? || trigger.last_follow_up_dropped?
      Rails.logger.warn "#{github_log_tag} Trigger #{trigger.id} dropped the follow-up for " \
                        "#{item_key(item)} (#{event}); leaving it unseen so the next tick retries"
      return false
    end

    Rails.logger.info "#{github_log_tag} Created session #{session.id} for trigger " \
                      "#{trigger.id} from #{item_key(item)} (#{event})"
    true
  rescue => e
    # A raise is NOT proof that nothing was created. Session.create_from_agent_root!
    # commits the session row and then enqueues its one AgentSessionJob, and
    # Trigger#create_session! keeps going afterwards — the reuse pointer, the
    # sessions_created counter, the missed-fire clear. Anything from the enqueue
    # onward can raise over a live session row, and returning false here would
    # leave the item unseen and hand the next tick, sixty seconds later, an event
    # that already has a session.
    #
    # That is defect 1 of #704: trigger 352 spawned TWO merge-gate sessions for one
    # `ready to merge` label, 55s and 43s apart, on the one mechanism authorized to
    # merge without human sign-off — a double-merge race whenever both dispatch.
    #
    # So the question is not "did this method return cleanly" but "does a session
    # exist for this item", and Trigger#last_fire_created_session answers it. When
    # one does, the event is consumed: report the failure loudly, and treat the item
    # as fired so it is never spawned for twice.
    #
    # A session that was created but whose start job did not survive the failure is
    # defect 2 of the same issue, and it has its own owner: StalledStartSweepJob
    # restarts a `waiting` session with no job (#737). Re-firing here would not have
    # rescued it either — it would have spawned a sibling and left the original
    # stranded regardless, which is precisely what happened to session 10426.
    created = spawn_attempted ? trigger.last_fire_created_session : nil
    if created
      Rails.logger.error "#{github_log_tag} Trigger #{trigger.id} created session " \
                         "#{created.id} for #{item_key(item)} (#{event}) but the fire then failed: " \
                         "#{e.message}. Treating the event as fired — the session exists, so " \
                         "re-firing would spawn a duplicate. If it never starts, StalledStartSweepJob owns it."
      return true
    end

    Rails.logger.error "#{github_log_tag} Failed to create session for " \
                       "#{item_key(item)} (#{event}): #{e.message}"
    false
  end

  def github_log_tag
    "[#{self.class.name}]"
  end

  # Whether this fire takes a claim. The webhook always does; the poller does only while the webhook
  # is switched on, so on `poll` it claims nothing and takes no lock. Both GitHub condition types
  # are served by the webhook (Webhooks::Source.github#served_conditions), so both claim.
  def claims_github_event?(via)
    via == "webhook" || Webhooks::Source.github.webhook_enabled?
  end

  # The event +item+ and +label+ identify, for +condition+'s type. A `github_label` fire without a
  # label has no event to claim, and claiming the wrong key is how one path swallows the other's
  # event, so this refuses rather than inventing one.
  def github_claim_key(condition, item, label)
    return TriggerEventClaim.github_issue_event_key(repo_of(item), item["number"]) unless condition.condition_type == "github_label"
    raise ArgumentError, "a github_label fire for #{item_key(item)} names no label" if label.blank?

    TriggerEventClaim.github_label_event_key(repo_of(item), item["number"], label)
  end

  # #fire for a claiming path. Returns true when a session exists for the event — this path's, or
  # the other path's, which claimed it first — and false when nothing was spawned, so the poller
  # leaves the event unfired and retries it, exactly as it does without claims.
  #
  # Inside the transaction the trigger's spawn lock comes first (Trigger.lock_spawn_for_transaction!),
  # so two fires of one trigger see each other's sessions, then the claim, then the spawn. A spawn
  # that produces nothing — burst control, a pending session, a dropped follow-up — releases the claim
  # rather than keeping it: a new issue and a label that is still on the item are both durable state,
  # and the poller fires them once whatever held it back has cleared, as it would with no webhook at
  # all. A spawn that raises rolls the session and the claim back together, so unlike the unclaimed
  # path (#704) there is no created session to account for.
  #
  # ## How this composes with #704's rescue, which is what the merge gate fires through
  #
  # #704 is the label path's own incident: one `ready to merge` label produced two merge-gate
  # sessions 55s apart, and #fire's rescue closes it by asking "does a session exist for this item"
  # (Trigger#last_fire_created_session) rather than "did this method return cleanly". Two things are
  # worth stating about what happens to that reasoning here, because the merge gate is the one
  # mechanism authorized to merge without human sign-off.
  #
  # **The claim is strictly stronger than the rescue, and it is why this path is safe.** #704's
  # rescue prevents a duplicate only if its CALLER then records the item — the poller's
  # #record_fired_key, or its end-of-tick write. Lose that write, which is the exact failure the
  # durability floor exists for, and the next tick fires again anyway. A committed claim needs
  # nothing from the caller: the second fire loses it whatever the seen-set says.
  #
  # **So the rescue asks the database instead of the trigger.** `last_fire_created_session` is an
  # in-memory report about a transaction that may have rolled back — it would name a session row
  # that no longer exists, and consuming the event on it would swallow a label event with nothing to
  # show for it (#647's direction, and the worse one on the gate). `Session.exists?` is the only
  # honest question here, and the only case it can answer yes to is a raise from an `after_commit`
  # callback, which arrives after the session and the claim have both committed.
  #
  # The one thing a label event needs that an issue does not is for that decision to EXPIRE: the
  # label can come off and go back on. It does, because the claim does — GithubTriggerPollerJob
  # releases it the tick it drops the item from its seen-set.
  def fire_claimed(condition, item, event:, via:, label: nil)
    trigger = condition.trigger
    prompt = github_fire_prompt(trigger, item, event: event)
    key = github_claim_key(condition, item, label)
    outcome = nil

    ActiveRecord::Base.transaction do
      Trigger.lock_spawn_for_transaction!(trigger.id)

      if TriggerEventClaim.claim!(condition, [ key ], via: via).empty?
        outcome = :claimed_elsewhere
        next
      end

      session = trigger.create_session!(prompt: prompt)

      if session.nil? || trigger.last_follow_up_dropped?
        TriggerEventClaim.where(trigger_condition_id: condition.id, event_key: key).delete_all
        outcome = :not_spawned
        next
      end

      TriggerEventClaim.attach_session!(condition, [ key ], session)
      outcome = session
    end

    case outcome
    when :claimed_elsewhere
      Rails.logger.info "#{github_log_tag} Condition #{condition.id} already fired for #{item_key(item)} (#{event}) — " \
                        "the other delivery path claimed it first; skipping"
      true
    when :not_spawned
      # The same levels as the unclaimed path: holding back for a burst or a pending session is
      # expected, while a dropped follow-up is worth a WARN.
      if trigger.last_fire_burst_suppressed?
        Rails.logger.info "#{github_log_tag} Trigger #{trigger.id} is burst-suppressed for #{item_key(item)} (#{event}); " \
                          "released its claim so the issue fires once the burst ends"
      elsif trigger.last_fire_skipped_for_pending_session?
        Rails.logger.info "#{github_log_tag} Trigger #{trigger.id} skipped #{item_key(item)} (#{event}) — session " \
                          "#{trigger.last_fire_pending_session&.id} is still pending; released its claim"
      else
        Rails.logger.warn "#{github_log_tag} Trigger #{trigger.id} dropped the follow-up for #{item_key(item)} (#{event}); " \
                          "released its claim so the next tick retries"
      end
      false
    else
      Rails.logger.info "#{github_log_tag} Created session #{outcome.id} for trigger #{trigger.id} from " \
                        "#{item_key(item)} (#{event}) via #{via}"
      true
    end
  rescue => e
    # A raise inside the block rolls the session and the claim back together. One from an
    # after_commit callback arrives after both have committed, so ask the database which it was:
    # a session that exists has fired, and its claim keeps the other path from firing it again.
    # This is #704's question with the evidence taken from the database rather than from the
    # trigger — see the note above this method for why that difference is load-bearing here.
    if outcome.is_a?(Session) && Session.exists?(id: outcome.id)
      Rails.logger.error "#{github_log_tag} Trigger #{trigger.id} created session #{outcome.id} for #{item_key(item)} " \
                         "(#{event}) via #{via}, but the fire then failed after commit: #{e.message}. Treating the event as fired"
      return true
    end

    Rails.logger.error "#{github_log_tag} Failed to create session for #{item_key(item)} (#{event}) via #{via}: " \
                       "#{e.message}. The claim rolled back with it, so the event is still unfired"
    report_webhook_fire_failure(condition, item, e) if via == "webhook"
    false
  end

  # The poller's failures page through its own ERROR line on every tick they recur. A webhook fire is
  # tried once, so it reports here; WARN level, because the poller is still the backstop.
  def report_webhook_fire_failure(condition, item, error)
    ErrorReporter.report_exception(
      error,
      level: :warning,
      context: {
        title: "GitHub webhook trigger fire failed",
        source: self.class.name,
        details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}) " \
                 "failed to fire for #{item_key(item)}. The poller is the backstop for this event.",
        condition_id: condition.id,
        trigger_id: condition.trigger_id
      }
    )
  end

  # The prompt a fire of +trigger+ for +item+ spawns with: the template, plus the item itself when
  # the template does not name it. Rendered the same way whichever path found the item.
  def github_fire_prompt(trigger, item, event:)
    prompt = trigger.interpolate_prompt(
      link: item["html_url"],
      text: body_of(item),
      author: item.dig("user", "login"),
      event: event,
      repo: repo_of(item),
      number: item["number"],
      title: item["title"],
      labels: labels_for(item)
    )

    # A template that names no GitHub variable would otherwise hand the session a prompt
    # with no idea which PR it is about. Append the item rather than firing blind.
    prompt = "#{prompt}\n\n#{context_block(trigger, item, event: event)}" unless trigger.references_github_context?

    prompt
  end

  # The item for a template that does not identify it. Repository, number, URL and author
  # login are fields of the API result. The title, labels and body are text people chose,
  # so each renders the way the template renders {{title}}, {{labels}} and {{text}}: fenced,
  # unless the template writes that placeholder bare (Trigger#render_appended_untrusted).
  # The URL line stays above all three — OrphanedTriggerFire reads the first one. A cut body's
  # truncation marker is Zimmer's, so it goes after the fence.
  def context_block(trigger, item, event:)
    labels = labels_for(item).presence&.join(", ")
    body = item["body"].to_s
    body_text = if body.blank?
      "(no description)"
    else
      fenced = trigger.render_appended_untrusted(body[0, MAX_BODY_LENGTH], variable: "text", name: "body")
      body.length > MAX_BODY_LENGTH ? "#{fenced}\n\n…(truncated)" : fenced
    end

    <<~TEXT.strip
      ## GitHub #{pull_request?(item) ? 'pull request' : 'issue'} (#{event})

      - **Repository:** #{repo_of(item)}
      - **Number:** ##{item['number']}
      - **URL:** #{item['html_url']}
      - **Author:** #{item.dig('user', 'login') || 'unknown'}

      ### Title

      #{trigger.render_appended_untrusted(item['title'], variable: 'title')}

      ### Labels

      #{labels ? trigger.render_appended_untrusted(labels, variable: 'labels') : '(none)'}

      ### Body

      #{body_text}
    TEXT
  end

  def body_of(item)
    body = item["body"].to_s
    body.length > MAX_BODY_LENGTH ? "#{body[0, MAX_BODY_LENGTH]}\n\n…(truncated)" : body
  end
end
