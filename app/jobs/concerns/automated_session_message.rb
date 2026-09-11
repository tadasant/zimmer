# frozen_string_literal: true

# Delivery for automated, poller-originated messages to a session.
#
# Every poller that notices a GitHub state change worth telling a session about
# (a merge conflict appearing, a PR merging) has the same delivery problem: the
# session may be parked in needs_input, where the message should wake it now, or
# it may not be able to take a prompt this instant, in which case the notice goes
# into the durable queue. This is that one decision, made in one place, so a new
# automated message is a prompt and a call rather than a second delivery path.
#
# WHAT THE `else` BRANCH RELIES ON, stated because reading it as "waits behind the
# current turn" is wrong for half of what lands there, and that misreading is what
# tadasant/zimmer#1123 was filed about. Queueing is safe for a session MID-TURN,
# which has a turn boundary coming. It is NOT self-evidently safe for a session at
# REST in `waiting` — asleep on an `open-pr` self-wake, or with that wake budget
# spent — because nothing about that state produces a next turn on its own.
#
# What makes it safe is not this branch: it is EnqueuedMessage's after_create_commit
# hook, which schedules EnqueuedMessageDrainJob for any session that is already idle
# by Session#idle_for_queued_delivery? — BOTH resting states, not just needs_input
# (#566). That job re-reads the session under its own rules and either delivers the
# message or names the population of `waiting` that genuinely cannot take one, each
# of which has something else coming that ends in a turn boundary.
#
# So the invariant is "a queued notice always has something coming back for it", and
# it is owned over there. Do not weaken this branch on the assumption that a `waiting`
# session will get around to its queue by itself.
#
module AutomatedSessionMessage
  extend ActiveSupport::Concern

  # with_db_retry is part of this delivery path, so the dependency is taken rather
  # than documented: an includer that forgot it would raise NoMethodError inside the
  # rescue below and lose the message silently. Including it twice is a no-op.
  included do
    include DatabaseRetry
  end

  private

  # Deliver an automated prompt to a session — immediately if it is waiting for
  # input, otherwise at its next turn boundary.
  #
  # Failures are logged and swallowed: a poller sweeps many sessions, and one
  # session that cannot take a message must not abort the sweep for the rest.
  #
  # @param session [Session] the session to message
  # @param prompt [String] the AutomatedPrompts message to deliver
  # @param event_description [String] what happened, for the session log — e.g.
  #   "Merge conflict detected on https://github.com/owner/repo/pull/1"
  # @param origin [String] an EnqueuedMessage::ORIGINS value naming which notice
  #   this is. It reaches the row only on the queued branch, which is the only
  #   branch where anything reads it: an immediate send has no row, because the
  #   session takes the prompt straight away.
  # @return [Boolean] true when the message was delivered or queued, false when
  #   it was not. A caller that records "this session has been told" should key
  #   off this rather than off having tried, so its marker never claims a
  #   delivery that did not happen.
  def deliver_automated_message(session, prompt, event_description:, origin:)
    with_db_retry do
      ActiveRecord::Base.transaction do
        session.lock!

        if session.needs_input?
          send_prompt_immediately(session, prompt, event_description)
        else
          enqueue_prompt_for_later(session, prompt, event_description, origin)
        end
      end
    end

    true
  rescue => e
    Rails.logger.error "[#{self.class.name}] Failed to deliver automated message to session #{session.id} " \
      "(#{event_description}): #{e.message}"
    false
  end

  # Send the prompt directly to the session, queuing its turn for a worker
  # Used when session is in needs_input state
  def send_prompt_immediately(session, prompt, event_description)
    session.logs.create!(
      content: "#{event_description} — automated message sent immediately",
      level: "info"
    )

    session.deliver_follow_up!(prompt, clear_metadata_keys: Session::SIGTERM_RETRY_METADATA_KEYS)

    Rails.logger.info "[#{self.class.name}] Sent immediate automated message to session #{session.id} (#{event_description})"
  end

  # Queue the prompt as an enqueued message for later processing.
  #
  # Used for every session that is not parked in needs_input — mid-turn, or at rest
  # in `waiting`. EnqueuedMessage's after_create_commit hook is what guarantees
  # something comes back for the row in the second case; see the class comment.
  def enqueue_prompt_for_later(session, prompt, event_description, origin)
    max_position = session.enqueued_messages.maximum(:position) || 0
    next_position = max_position + 1

    session.enqueued_messages.create!(
      content: prompt,
      position: next_position,
      status: "pending",
      origin: origin
    )

    session.logs.create!(
      content: "#{event_description} — automated message enqueued",
      level: "info"
    )

    Rails.logger.info "[#{self.class.name}] Enqueued automated message for session #{session.id} (#{event_description})"
  end
end
