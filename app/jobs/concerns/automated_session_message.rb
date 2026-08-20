# frozen_string_literal: true

# Delivery for automated, poller-originated messages to a session.
#
# Every poller that notices a GitHub state change worth telling a session about
# (a merge conflict appearing, a PR merging) has the same delivery problem: the
# session may be parked in needs_input, where the message should wake it now, or
# mid-turn in running/waiting, where it has to wait its turn behind whatever the
# agent is already doing. This is that one decision, made in one place, so a new
# automated message is a prompt and a call rather than a second delivery path.
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

  # Send prompt directly to the session, transitioning it to running
  # Used when session is in needs_input state
  def send_prompt_immediately(session, prompt, event_description)
    session.logs.create!(
      content: "#{event_description} — automated message sent immediately",
      level: "info"
    )

    session.deliver_follow_up!(prompt, clear_metadata_keys: Session::SIGTERM_RETRY_METADATA_KEYS)

    Rails.logger.info "[#{self.class.name}] Sent immediate automated message to session #{session.id} (#{event_description})"
  end

  # Queue prompt as an enqueued message for later processing
  # Used when session is running or waiting
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
