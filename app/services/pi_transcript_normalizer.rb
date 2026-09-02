# frozen_string_literal: true

# TranscriptNormalizer for the Pi coding agent runtime.
#
# Maps Pi's session JSONL onto OpenTranscripts v0.1 events (see OpenTranscript
# and https://docs.zimmer.tadasant.com/sessions/transcripts/). A Pi session file
# is a TREE, not a flat log: every line after the header carries `id`/`parentId`,
# and branching (`/tree`, `/fork`) creates siblings rather than a new file.
#
#   {"type":"session","version":3,"id":"<uuid>","timestamp":"...","cwd":"..."}
#   {"type":"message","id":"a1b2c3d4","parentId":null,"timestamp":"...","message":{...}}
#   {"type":"model_change","id":"...","parentId":"...","provider":"...","modelId":"..."}
#   {"type":"compaction","id":"...","parentId":"...","summary":"...","tokensBefore":N}
#
# Zimmer's timeline is flat and chronological, so the tree is deliberately NOT
# reconstructed here: entries are normalized in file order, which is the order
# they happened. The tree links are not preserved either: `provider_raw` carries
# the inner AgentMessage for message entries, which has no `parentId` — only the
# outer entry does. Nothing downstream needs the shape today, and carrying the
# outer entry would put a second copy of every message body in `provider_raw`.
#
# == One entry can produce several events ==
#
# This is the substantive difference from the Codex normalizer. A Codex rollout
# line holds exactly one thing. A Pi `assistant` message holds an ARRAY of
# content blocks that can mix `text`, `thinking` and `toolCall` in a single
# entry, and each maps to a different OpenTranscripts event type. So #normalize
# returns the assistant message plus its Thinking and ToolCall events, ordered by
# `event_order` so the timeline renders them in the order the model emitted them.
#
# Pi has no subagent concept, so the subagent extractors always return [].
class PiTranscriptNormalizer < TranscriptNormalizer
  # Entry types that are pure bookkeeping — no conversation, nothing to render.
  #
  # `custom` is on this list and `custom_message` deliberately is not: Pi's own
  # format doc draws exactly that line ("CustomEntry ... does NOT participate in
  # LLM context" vs "CustomMessageEntry — extension-injected messages that DO").
  NON_CONVERSATION_TYPES = %w[session model_change thinking_level_change label session_info custom].freeze

  # @see TranscriptNormalizer#normalize
  #
  # @return [Array<Hash>] zero or more OpenTranscripts events for one entry
  def normalize(raw_event, session:, transcript_index: nil)
    return [] unless raw_event.is_a?(Hash)

    ts_string, sort_time = OpenTranscript.resolve_ts(raw_event["timestamp"], session.created_at)
    ctx = {
      raw_event: raw_event,
      ts_string: ts_string,
      sort_time: sort_time,
      transcript_index: transcript_index
    }

    case raw_event["type"]
    when "message"          then build_message_events(raw_event["message"], ctx)
    when "custom_message"   then build_custom_message_events(raw_event, ctx)
    when "compaction"       then build_compaction_events(raw_event, ctx)
    when "branch_summary"   then build_branch_summary_events(raw_event, ctx)
    else []
    end
  end

  # @see TranscriptNormalizer#extract_session_id
  #
  # The session UUID lives on the header line's `id`. Zimmer already knows it —
  # it minted it and passed `--session-id` — so this exists for completeness and
  # for the poller's consistency check rather than to discover anything.
  def extract_session_id(raw_event)
    return nil unless raw_event.is_a?(Hash)
    return nil unless raw_event["type"] == "session"

    raw_event["id"]
  end

  # @see TranscriptNormalizer#mints_own_session_id?
  #
  # FALSE, and this is the correctness-critical one. Pi accepts `--session-id`
  # and creates the session with exactly that id, so the id in the transcript is
  # Zimmer's own — there is nothing to capture. Answering true here would make
  # the poller write the id back over itself and, worse, make forked sessions
  # collide on the unique `session_id` index (see the agent-harness doc's note on
  # this method, and zimmer#96).
  def mints_own_session_id?
    false
  end

  # @see TranscriptNormalizer#extract_subagent_links
  #
  # Pi has no subagent concept.
  def extract_subagent_links(raw_event)
    []
  end

  # @see TranscriptNormalizer#extract_subagent_spawns
  #
  # Pi has no subagent concept.
  def extract_subagent_spawns(raw_event)
    []
  end

  # @see TranscriptNormalizer#conversation_record?
  #
  # A DENY-list, as the harness doc requires: a Pi session file always opens with
  # a `session` header and normally carries `model_change` and
  # `thinking_level_change` entries before the first prompt is even sent, so a
  # file holding only those is a file with no conversation in it. Every other
  # entry type — including one this normalizer does not render — counts as
  # conversation, so a Pi version that adds an entry type cannot cause a real
  # history to be thrown away.
  def conversation_record?(raw_event)
    return false unless raw_event.is_a?(Hash)

    !NON_CONVERSATION_TYPES.include?(raw_event["type"])
  end

  private

  # Stable per-entry event id. Pi gives every entry its own 8-char hex `id`,
  # which is a better base than the transcript index because it survives
  # re-reads; the index is the fallback for the header and any entry without one.
  def event_id(ctx, suffix = "")
    entry_id = ctx[:raw_event]["id"].presence
    base = entry_id ? "pi-#{entry_id}" : "pi-#{ctx[:transcript_index] || ctx[:raw_event].object_id}"
    suffix.empty? ? base : "#{base}:#{suffix}"
  end

  def base_event(ctx, type:, id_suffix: "", event_order: 0, provider_raw: nil, **fields)
    OpenTranscript.event(
      type: type,
      id: event_id(ctx, id_suffix),
      parent_id: nil,
      ts: ctx[:ts_string],
      sort_time: ctx[:sort_time],
      provider_raw: provider_raw,
      transcript_index: ctx[:transcript_index],
      event_order: event_order,
      **fields
    )
  end

  # A `{"type":"message"}` entry, whose `message` is one of Pi's AgentMessage
  # variants distinguished by `role`.
  def build_message_events(message, ctx)
    return [] unless message.is_a?(Hash)

    case message["role"]
    when "user"              then build_user_message(message, ctx)
    when "assistant"         then build_assistant_events(message, ctx)
    when "toolResult"        then build_tool_result(message, ctx)
    when "bashExecution"     then build_bash_execution_events(message, ctx)
    when "custom"            then build_custom_role_message(message, ctx)
    when "compactionSummary" then build_compaction_summary(message, ctx)
    when "branchSummary"     then build_branch_summary_message(message, ctx)
    else []
    end
  end

  def build_user_message(message, ctx)
    parts = content_parts(message["content"])
    return [] if parts.empty?

    [ base_event(ctx, type: OpenTranscript::Types::USER_MESSAGE, provider_raw: message, content: parts) ]
  end

  # An assistant entry fans out into up to three kinds of event: the message
  # itself (carrying the renderable text plus the model/usage/stop metadata),
  # one Thinking event per `thinking` block, and one ToolCall per `toolCall`
  # block.
  #
  # The assistant message is emitted even when it holds no text — the harness
  # doc's note on OpenTranscript.blank_message? explains why: it carries the
  # usage and model metadata and anchors the entry, and the renderer already
  # knows not to draw a bare row for it.
  def build_assistant_events(message, ctx)
    blocks = message["content"]
    blocks = [] unless blocks.is_a?(Array)

    events = [ base_event(
      ctx,
      type: OpenTranscript::Types::ASSISTANT_MESSAGE,
      provider_raw: message,
      content: blocks.filter_map { |b| text_part_for(b) },
      model: assistant_model(message),
      stop_reason: message["stopReason"],
      usage: normalize_usage(message["usage"]),
      cost_usd: message.dig("usage", "cost", "total")
    ) ]

    blocks.each_with_index do |block, index|
      next unless block.is_a?(Hash)

      case block["type"]
      when "thinking"
        text = block["thinking"]
        next if text.blank?

        events << base_event(
          ctx,
          type: OpenTranscript::Types::THINKING,
          id_suffix: "thinking-#{index}",
          event_order: events.length,
          provider_raw: block,
          text: text,
          signature: nil,
          redacted: false
        )
      when "toolCall"
        events << base_event(
          ctx,
          type: OpenTranscript::Types::TOOL_CALL,
          id_suffix: "toolcall-#{index}",
          event_order: events.length,
          provider_raw: block,
          tool_call_id: block["id"],
          tool_name: block["name"],
          arguments: block["arguments"].is_a?(Hash) ? block["arguments"] : {}
        )
      end
    end

    events
  end

  def build_tool_result(message, ctx)
    [ base_event(
      ctx,
      type: OpenTranscript::Types::TOOL_RESULT,
      provider_raw: message,
      tool_call_id: message["toolCallId"],
      output: content_parts(message["content"]),
      is_error: !!message["isError"]
    ) ]
  end

  # A `!`-prefixed shell command the USER ran in Pi's interactive mode. It is not
  # a model tool call, but it is conversation — it went into the context and the
  # user expects to see it — so it renders as a ToolCall/ToolResult pair, which
  # is the shape the timeline already knows how to draw for "a command ran and
  # produced output".
  #
  # `excludeFromContext` marks a `!!` command that Pi deliberately kept OUT of
  # the model's context. It still ran and the user still typed it, so it is still
  # shown; the flag rides along in provider_raw.
  def build_bash_execution_events(message, ctx)
    command = message["command"]
    return [] if command.blank?

    call_id = event_id(ctx, "bash")
    [
      base_event(
        ctx,
        type: OpenTranscript::Types::TOOL_CALL,
        id_suffix: "bash",
        provider_raw: message,
        tool_call_id: call_id,
        tool_name: "bash",
        arguments: { "command" => command }
      ),
      base_event(
        ctx,
        type: OpenTranscript::Types::TOOL_RESULT,
        id_suffix: "bash-result",
        event_order: 1,
        provider_raw: message,
        tool_call_id: call_id,
        output: [ OpenTranscript.text_part(message["output"].to_s) ],
        is_error: message["exitCode"].present? && message["exitCode"] != 0
      )
    ]
  end

  # An extension-injected message that DOES participate in LLM context, arriving
  # either as a `custom_message` ENTRY or as a message with role `custom`. Both
  # carry the same fields, so both land here.
  #
  # Rendered as a SystemEvent rather than a UserMessage: the human did not say
  # it, and attributing an extension's injected context to the user is exactly
  # the confusion SystemEvent exists to avoid. The `customType` names the
  # extension that wrote it, which is the useful thing to show.
  def build_custom_message(source, ctx, id_suffix: "")
    parts = content_parts(source["content"])
    return [] if parts.empty?

    [ base_event(
      ctx,
      type: OpenTranscript::Types::SYSTEM_EVENT,
      id_suffix: id_suffix,
      subtype: source["customType"].presence || "pi-extension",
      payload: source
    ) ]
  end

  def build_custom_message_events(entry, ctx)
    build_custom_message(entry, ctx)
  end

  def build_custom_role_message(message, ctx)
    build_custom_message(message, ctx)
  end

  # A `{"type":"compaction"}` ENTRY — the context-compaction checkpoint.
  def build_compaction_events(entry, ctx)
    summary = entry["summary"]
    return [] if summary.blank?

    [ base_event(
      ctx,
      type: OpenTranscript::Types::COMPACTION,
      provider_raw: entry,
      summary: summary.to_s,
      first_kept_event_id: entry["firstKeptEntryId"],
      tokens_before: entry["tokensBefore"],
      tokens_after: nil,
      trigger: entry["fromHook"] ? "extension" : nil
    ) ]
  end

  # The same checkpoint arriving as a MESSAGE with role `compactionSummary`,
  # which is how buildSessionContext materializes it.
  def build_compaction_summary(message, ctx)
    summary = message["summary"]
    return [] if summary.blank?

    [ base_event(
      ctx,
      type: OpenTranscript::Types::COMPACTION,
      provider_raw: message,
      summary: summary.to_s,
      first_kept_event_id: nil,
      tokens_before: message["tokensBefore"],
      tokens_after: nil,
      trigger: nil
    ) ]
  end

  # A `/tree` branch switch, summarizing the branch that was left. Rendered as a
  # Compaction because it is the same idea — earlier turns replaced by a summary
  # — and the timeline already draws that boundary.
  def build_branch_summary_events(entry, ctx)
    summary = entry["summary"]
    return [] if summary.blank?

    [ base_event(
      ctx,
      type: OpenTranscript::Types::COMPACTION,
      provider_raw: entry,
      summary: summary.to_s,
      first_kept_event_id: entry["fromId"],
      tokens_before: nil,
      tokens_after: nil,
      trigger: "branch_summary"
    ) ]
  end

  def build_branch_summary_message(message, ctx)
    summary = message["summary"]
    return [] if summary.blank?

    [ base_event(
      ctx,
      type: OpenTranscript::Types::COMPACTION,
      provider_raw: message,
      summary: summary.to_s,
      first_kept_event_id: message["fromId"],
      tokens_before: nil,
      tokens_after: nil,
      trigger: "branch_summary"
    ) ]
  end

  # Pi content is either a bare String (the shorthand a UserMessage may use) or
  # an array of typed blocks. Both fold into ContentPart[].
  def content_parts(content)
    case content
    when String
      content.present? ? [ OpenTranscript.text_part(content) ] : []
    when Array
      content.filter_map { |block| content_part(block) }
    else
      []
    end
  end

  def content_part(block)
    return nil unless block.is_a?(Hash)

    case block["type"]
    when "text"
      text_part_for(block)
    when "image"
      OpenTranscript.image_part(data: block["data"], mime_type: block["mimeType"])
    end
  end

  def text_part_for(block)
    return nil unless block.is_a?(Hash)
    return nil unless block["type"] == "text"

    text = block["text"]
    text.present? ? OpenTranscript.text_part(text) : nil
  end

  # Pi records the provider and the model id separately. The provider-qualified
  # form is what Zimmer's ModelCatalog uses and what `--model` accepts, so it is
  # the form worth surfacing.
  def assistant_model(message)
    model = message["model"]
    return nil if model.blank?

    provider = message["provider"]
    provider.present? ? "#{provider}/#{model}" : model
  end

  # Pi's Usage carries token counts alongside a nested per-bucket cost breakdown.
  # Only the counts belong in the OpenTranscripts usage field; the total cost is
  # carried separately in cost_usd.
  def normalize_usage(usage)
    return nil unless usage.is_a?(Hash)

    {
      "input" => usage["input"],
      "output" => usage["output"],
      "cache_read" => usage["cacheRead"],
      "cache_write" => usage["cacheWrite"],
      "total" => usage["totalTokens"]
    }.compact.presence
  end
end
