# frozen_string_literal: true

module McpEvents
  # Whose words an `mcp_event` fire delivered into a session, as far as Zimmer can establish it.
  #
  # One kind of event can be attributed: a Slack message read back from Slack (SlackMessage) whose
  # author is on the roster. Nothing else is, and for two of the feeds it never could be. A Gmail
  # event's `from` is a header the sender writes. A WhatsApp event's `sender_jid` is the bridge's
  # account of a sender Zimmer cannot ask WhatsApp about, and no roster row maps one.
  #
  # An event that is not attributed leaves the session marked `incomplete`, which is what stops
  # HumanMessageCaptureCoverage reading an empty record there as "nobody spoke". A bot's alert is
  # marked the same way: "not established" is true of it, and only overcautious.
  module HumanCapture
    # On the session's metadata: "complete" when every event that started it was attributed,
    # "incomplete" when any event delivered into it was not. Absent means the fire predates the
    # marker, or the session was not started by an event, and HumanMessageCaptureCoverage reads an
    # event-started session without it as incomplete.
    METADATA_KEY = "mcp_event_human_capture"
    COMPLETE = "complete"
    INCOMPLETE = "incomplete"

    module_function

    # Call inside the transaction that delivered +occurrences+ into +session+, so the record commits
    # before the session's job can read it.
    #
    # @param slack_messages [Hash{String => SlackMessage, nil}] by event id
    # @param started [Boolean] whether these events are what created the session
    def record!(session, condition, occurrences, slack_messages:, started:)
      complete = occurrences.map { |occurrence| record_one(session, condition, occurrence, slack_messages[occurrence.event_id]) }.all?

      if !complete
        mark_incomplete!(session)
      elsif started
        session.merge_metadata!(METADATA_KEY => COMPLETE)
      end
    end

    def mark_incomplete!(session)
      session.merge_metadata!(METADATA_KEY => INCOMPLETE)
    end

    # Whether an event's words are in +session+'s conversation, or may be. A fork of such a session
    # carries the conversation and none of the records, so ForkSessionService marks it incomplete.
    def reached?(session)
      metadata = session.metadata.to_h
      metadata.key?("mcp_event_server") || metadata.key?(METADATA_KEY) || session.genesis == SessionGenesis::MCP_EVENT
    end

    def record_one(session, condition, occurrence, message)
      return nil if message&.author_id.nil?

      HumanMessageCapture.record_slack_message(
        session: session,
        slack_user_id: message.author_id,
        content: message.text,
        entry_point: message.dm? ? "mcp_event.slack_dm" : "mcp_event.slack_channel_message",
        slack_channel: message.channel_name,
        slack_permalink: message.permalink,
        occurred_at: message.occurred_at,
        provenance: { "mcp_event_server" => condition.mcp_event_server, "mcp_event_id" => occurrence.event_id }
      )
    end
  end
end
