# frozen_string_literal: true

# Writes HumanMessage records.
#
# This is the ONLY way one is created, and it exists so the rule can be stated
# in one place: capture keys off the *authenticated actor at the input
# boundary*, never off the text of the message.
#
# That distinction is the whole feature. `follow_up` issued by Tadas in the
# browser and `follow_up` issued by another agent session over MCP arrive as the
# same kind of `user` turn and end up in the same delivery path — the only thing
# that tells them apart is which controller/tool accepted the request. So the
# boundaries call in explicitly:
#
#   * SessionsController / EnqueuedMessagesController (the browser)
#       → User.admin, because Zimmer has no login and exactly one human can
#         reach the UI. Which user that is comes from the ZIMMER_ADMIN_USER
#         deployment config, not from anything in the request.
#   * SlackTriggerPollerJob (a real Slack message)
#       → User.for_slack_user_id(message.user).
#
# Sessions carry an `auth_identity_email` in metadata that often matches a
# User#email, and it is tempting to attribute from it. It is NOT wired here:
# AuthRecoveryCoordinator writes it to name the pooled Claude login the *agent
# process* was spawned with, so it describes a machine's credentials, not the
# person who typed. Attributing from it would say a human asked for something
# every time an agent ran under Tadas's account. If Zimmer ever
# grows real per-human login, the request's authenticated email is what would
# resolve through User.for_email — at the boundary, from the actor, same rule.
#
# Nothing else calls this. Api::V1 controllers, McpController and every MCP tool
# authenticate an API key, not a person: an API key is shared by the whole fleet
# and establishes no human author, so those paths deliberately record nothing.
#
# Every method is best-effort: a capture failure must never break the delivery
# of the message it was describing. A missing record is a safe outcome.
class HumanMessageCapture
  class << self
    # Record a message typed by a human into the Zimmer web UI.
    #
    # @param session [Session] the session the human was speaking TO
    # @param content [String] the human's own words
    # @param entry_point [String] the specific boundary, e.g. "web_ui.follow_up"
    def record_web_ui_message(session:, content:, entry_point:, occurred_at: Time.current)
      record(
        session: session,
        author: User.admin,
        channel: HumanMessage::WEB_UI,
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
        author: User.for_slack_user_id(slack_user_id),
        channel: HumanMessage::SLACK,
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

    # @return [HumanMessage, nil] nil whenever the actor could not be
    #   established, the content is empty, or the write failed.
    def record(session:, author:, channel:, content:, occurred_at:, provenance:)
      return nil if session.nil? || !session.persisted?
      return nil if author.nil?

      body = content.to_s.strip
      return nil if body.blank?

      # Truncate rather than reject: an over-long message is still evidence a
      # human asked for something, and losing it entirely would be the worse
      # failure. The marker keeps the rendering honest about it.
      if body.length > HumanMessage::MAX_CONTENT_LENGTH
        body = "#{body[0, HumanMessage::MAX_CONTENT_LENGTH - 20]}\n…[truncated]"
      end

      # The savepoint is what makes the rescue below actually best-effort.
      #
      # Two of the call sites (SessionsController#follow_up, and any future one
      # inside an ActiveRecord::Base.transaction block) run with an enclosing
      # transaction open. In PostgreSQL a failed statement aborts the whole
      # transaction: rescuing the Ruby exception does NOT un-abort it, and every
      # later statement raises PG::InFailedSqlTransaction. Without
      # `requires_new: true` a capture failure would therefore take down the
      # follow-up delivery it was only supposed to describe — the exact opposite
      # of the guarantee this method is written to provide. The savepoint scopes
      # the rollback to this INSERT and leaves the caller's transaction usable.
      HumanMessage.transaction(requires_new: true) do
        session.human_messages.create!(
          author: author.key,
          channel: channel,
          content: body,
          occurred_at: occurred_at,
          provenance: provenance
        )
      end
    rescue => e
      # Capture is observational. If it fails, the message it describes still
      # has to reach the agent.
      Rails.logger.error("[HumanMessageCapture] Failed to record for session #{session&.id}: #{e.class}: #{e.message}")
      nil
    end
  end
end
