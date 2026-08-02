# frozen_string_literal: true

# Writes `human_message` events onto a session's Timeline.
#
# This is the ONLY way a TimelineEvent is created, and it exists so the rule can
# be stated in one place: capture keys off the *authenticated actor at the input
# boundary*, never off the text of the message.
#
# That distinction is the whole feature. `follow_up` issued by Tadas in the
# browser and `follow_up` issued by another agent session over MCP arrive as the
# same kind of `user` turn and end up in the same delivery path — the only thing
# that tells them apart is which controller/tool accepted the request. So the
# boundaries call in explicitly:
#
#   * SessionsController / EnqueuedMessagesController (the browser)
#       → HumanIdentity.web_ui, because Zimmer has no login and exactly one
#         human can reach the UI.
#   * SlackTriggerPollerJob (a real Slack message)
#       → HumanIdentity.for_slack_user_id(message.user).
#
# Nothing else calls this. Api::V1 controllers, McpController and every MCP tool
# authenticate an API key, not a person: an API key is shared by the whole fleet
# and establishes no human author, so those paths deliberately record nothing.
#
# Every method is best-effort: a capture failure must never break the delivery
# of the message it was describing. A missing event is a safe outcome.
class TimelineCapture
  class << self
    # Record a message typed by a human into the Zimmer web UI.
    #
    # @param session [Session]
    # @param content [String] the human's own words
    # @param entry_point [String] the specific boundary, e.g. "web_ui.follow_up"
    # @param occurred_at [Time]
    def record_web_ui_message(session:, content:, entry_point:, occurred_at: Time.current)
      record(
        session: session,
        author: HumanIdentity.web_ui,
        channel: TimelineEvent::WEB_UI,
        content: content,
        occurred_at: occurred_at,
        provenance: { "entry_point" => entry_point }
      )
    end

    # Record a Slack message that resolved to a known human.
    #
    # `slack_user_id` is resolved through the configured map, NOT trusted as a
    # name: an unmapped ID (another workspace member, a bot, an app posting with
    # a bot token) yields nil and records nothing.
    def record_slack_message(session:, slack_user_id:, content:, entry_point:,
                             slack_channel: nil, slack_permalink: nil, occurred_at: Time.current)
      record(
        session: session,
        author: HumanIdentity.for_slack_user_id(slack_user_id),
        channel: TimelineEvent::SLACK,
        content: content,
        occurred_at: occurred_at,
        provenance: {
          "entry_point" => entry_point,
          "slack_user_id" => slack_user_id,
          "slack_channel" => slack_channel,
          "slack_permalink" => slack_permalink
        }.compact
      )
    end

    private

    # @return [TimelineEvent, nil] nil whenever the actor could not be
    #   established, the content is empty, or the write failed.
    def record(session:, author:, channel:, content:, occurred_at:, provenance:)
      return nil if session.nil? || !session.persisted?
      return nil if author.nil?

      body = content.to_s.strip
      return nil if body.blank?

      # Truncate rather than reject: an over-long message is still evidence a
      # human asked for something, and losing the event entirely would be the
      # worse failure. The marker keeps the rendering honest about it.
      if body.length > TimelineEvent::MAX_CONTENT_LENGTH
        body = "#{body[0, TimelineEvent::MAX_CONTENT_LENGTH - 20]}\n…[truncated]"
      end

      session.timeline_events.create!(
        event_type: TimelineEvent::HUMAN_MESSAGE,
        author: author.name,
        channel: channel,
        content: body,
        occurred_at: occurred_at,
        provenance: provenance
      )
    rescue => e
      # Capture is observational. If it fails, the message it describes still
      # has to reach the agent.
      Rails.logger.error("[TimelineCapture] Failed to record event for session #{session&.id}: #{e.class}: #{e.message}")
      nil
    end
  end
end
