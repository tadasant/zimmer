# frozen_string_literal: true

module McpEvents
  # A Slack message an `mcp_event` event announced, as Slack itself reports it.
  #
  # An event's payload says who wrote it only because the MCP server that published it says so, and
  # an `mcp_event` condition can poll any catalog server. So Zimmer takes nothing but a POINTER from
  # the payload, the channel and the message's `ts`, and reads the message back from Slack with its
  # own bot token. The author and the words are then Slack's answer to Zimmer, as on the native path
  # (SlackTriggerFiring), and a payload's `user_id` and `text` are never recorded as anybody's.
  #
  # The re-read establishes the author. It does not establish that the message is what this event is
  # about: a server could point at some other real message from the same person and have it recorded
  # against a session of its choosing. That is why a server also has to be named by the deployment
  # (SERVERS_ENV) before any of its events is read back. Unset, which is the default, names none.
  #
  # Everything here fails closed. A server not named, a payload whose pointer is malformed or
  # disagrees with its `eventId`, a message Slack does not return, or a Slack that does not answer
  # all come back nil, and the session is marked as one whose author was not established
  # (McpEvents::HumanCapture).
  class SlackMessage
    # Comma-separated catalog names of the MCP servers whose `message_posted` events announce Slack
    # messages in the workspace Zimmer's own bot token is for.
    SERVERS_ENV = "MCP_EVENT_SLACK_SERVERS"

    # The bare event name. A gateway prefixes it with the server's slug.
    EVENT_NAME = "message_posted"

    class << self
      def servers
        ENV[SERVERS_ENV].to_s.split(",").map(&:strip).reject(&:blank?)
      end

      def source?(server, event_name)
        servers.include?(server.to_s) && [ EVENT_NAME, "#{server}__#{EVENT_NAME}" ].include?(event_name.to_s)
      end

      # Makes Slack API calls, so call it outside any transaction. Never raises.
      #
      # @return [SlackMessage, nil]
      def read(condition, occurrence)
        return nil unless source?(condition.mcp_event_server, condition.mcp_event_name)

        channel_id, ts, thread_ts = pointer(occurrence)
        return nil if channel_id.nil?

        raw = SlackService.get_message(channel_id, ts, thread_ts: thread_ts)
        return nil if raw.nil?

        new(channel_id: channel_id, raw: raw, bot_user_id: SlackService.bot_user_id).tap(&:resolve_labels)
      rescue => e
        Rails.logger.warn "[McpEvents::SlackMessage] Could not read back #{occurrence.event_id} from Slack: #{e.class}: #{e.message}"
        nil
      end

      private

      # The channel, ts and parent ts the payload names, or nil unless all are well-formed Slack
      # identifiers and the event's id is the one that channel and ts make.
      def pointer(occurrence)
        data = occurrence.data.is_a?(Hash) ? occurrence.data : {}
        channel_id, ts, thread_ts = data.values_at("channel_id", "ts", "thread_ts").map { |value| value.to_s.presence }
        formats = Trigger::TRUSTED_IDENTIFIER_FORMATS

        return nil unless channel_id&.match?(formats.fetch("channel_id")) && ts&.match?(formats.fetch("message_ts"))
        return nil unless thread_ts.nil? || thread_ts.match?(formats.fetch("thread_ts"))
        return nil unless occurrence.event_id == TriggerEventClaim.slack_event_key(channel_id, ts)

        [ channel_id, ts, thread_ts ]
      end
    end

    attr_reader :channel_id, :permalink, :channel_name

    def initialize(channel_id:, raw:, bot_user_id: nil)
      @channel_id = channel_id
      @raw = raw
      @bot_user_id = bot_user_id
    end

    def ts = @raw.ts.to_s
    def thread_ts = @raw.thread_ts.presence&.to_s
    def text = @raw.text.to_s
    def dm? = channel_id.start_with?("D")

    # The Slack user ID of a PERSON who typed this, or nil. A message posted through an app carries
    # the app's `bot_id`, and one posted with a person's own user token carries that person in
    # `user` as well, so a `bot_id` means software wrote it whatever `user` says.
    def author_id
      return nil if @raw.bot_id.present? || @raw.app_id.present?

      @raw.user.presence
    end

    def occurred_at = Time.zone.at(ts.to_r)

    # What a native Slack condition would have called this fire. SlackErrorReply answers only the
    # two that are addressed to Zimmer.
    def event_type
      return "dm_message" if dm?

      @bot_user_id.present? && text.include?("<@#{@bot_user_id}>") ? "bot_mention" : "new_message"
    end

    # Display details for the record, best-effort: only a message from somebody on the roster is
    # ever recorded, so nobody else's costs the two calls.
    def resolve_labels
      return if author_id.nil? || User.for_slack_user_id(author_id).nil?

      @permalink = label { SlackService.get_message_permalink(channel_id, ts) }
      @channel_name = dm? ? "DM" : label { SlackService.get_channel(channel_id)&.name }
    end

    private

    def label
      yield
    rescue SlackService::SlackError => e
      Rails.logger.warn "[McpEvents::SlackMessage] Could not label #{channel_id}/#{ts}: #{e.class}: #{e.message}"
      nil
    end
  end
end
