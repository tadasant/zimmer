# TranscriptNormalizer for the Claude Code runtime.
#
# Maps Claude's JSONL message schema onto OpenTranscripts v0.1 events (see
# OpenTranscript and https://zimmer.tadasant.com/sessions/transcripts/). A Claude transcript line looks
# like:
#
#   { "type": "assistant",
#     "uuid": "<uuid>",
#     "parentUuid": "<uuid>",
#     "sessionId": "<uuid>",
#     "timestamp": "2025-11-20T10:00:00Z",
#     "message": { "role": "assistant",
#                  "content": [ { "type": "text", "text": "..." },
#                               { "type": "thinking", "thinking": "..." },
#                               { "type": "tool_use", "name": "Task", ... } ] },
#     "toolUseResult": { "agentId": "...", "status": "...", ... } }
#
# One source line can fan out into several events: an assistant line becomes an
# AssistantMessage plus a Thinking per thinking block plus a ToolCall (and a
# SubagentSpawn for Task/Agent tools) per tool_use block. A user line with
# tool_result blocks becomes one ToolResult per block.
#
# This port mirrors the reference `open_transcripts.py` / `cc_jsonl.py`
# converters with two documented Zimmer differences: no secret redaction, and
# per-line normalization (timestamps fall back to the session's created_at
# rather than carrying forward across lines). See https://zimmer.tadasant.com/sessions/transcripts/.
class ClaudeTranscriptNormalizer < TranscriptNormalizer
  SUBAGENT_TOOL_NAMES = %w[Task Agent].freeze

  # @see TranscriptNormalizer#normalize
  #
  # Returns an Array of OpenTranscripts events (possibly empty). The optional
  # subagents_by_tool_use_id map lets callers that have already correlated
  # subagents (tests, full-transcript assembly) populate SubagentSpawn's
  # spawned_transcript_id; the live per-line path leaves it nil (the UI resolves
  # the spawned transcript via tool_call_id at render time).
  def normalize(raw_event, session:, transcript_index: nil, subagents_by_tool_use_id: {})
    ts_string, sort_time = OpenTranscript.resolve_ts(raw_event["timestamp"], session.created_at)
    ctx = LineContext.new(
      raw_event: raw_event,
      ts_string: ts_string,
      sort_time: sort_time,
      transcript_index: transcript_index,
      subagents_by_tool_use_id: subagents_by_tool_use_id
    )

    case raw_event["type"]
    when "user"
      normalize_user_line(ctx)
    when "assistant"
      normalize_assistant_line(ctx)
    when "system"
      normalize_system_line(ctx)
    else
      normalize_other_line(ctx)
    end
  end

  # @see TranscriptNormalizer#extract_session_id
  def extract_session_id(raw_event)
    raw_event["sessionId"]
  end

  # @see TranscriptNormalizer#mints_own_session_id?
  #
  # Claude Code honors the Zimmer-supplied `--session-id` / `--resume <id>`, so the
  # stored session id is already authoritative — the poller must not re-learn it
  # from transcript content. This matters most for forked sessions: the fork's
  # transcript is copied verbatim from the source, so its early lines carry the
  # SOURCE session's `sessionId`. Capturing that would overwrite the fork's id
  # with the source's, colliding with the unique session_id index and failing the
  # poll (RecordNotUnique) until the session is marked transcript_unavailable.
  def mints_own_session_id?
    false
  end

  # @see TranscriptNormalizer#extract_subagent_links
  #
  # Subagent linkage lives on tool_result blocks whose toolUseResult carries an
  # agentId. The toolUseResult may sit on the block itself or on the top-level
  # event. Non-Hash toolUseResult values (e.g. Arrays from the TodoWrite tool)
  # are skipped to avoid type errors.
  def extract_subagent_links(raw_event)
    message_data = raw_event["message"] || raw_event
    content = message_data["content"]
    return [] unless content.is_a?(Array)

    content.filter_map do |block|
      next unless block["type"] == "tool_result"

      tool_use_result = block["toolUseResult"] || raw_event["toolUseResult"]
      next unless tool_use_result.is_a?(Hash)

      agent_id = tool_use_result["agentId"]
      next unless agent_id.present?

      {
        tool_use_id: block["tool_use_id"],
        agent_id: agent_id,
        status: tool_use_result["status"],
        duration_ms: tool_use_result["totalDurationMs"],
        total_tokens: tool_use_result["totalTokens"],
        tool_use_count: tool_use_result["totalToolUseCount"]
      }
    end
  end

  # @see TranscriptNormalizer#extract_subagent_spawns
  #
  # A subagent is spawned by a Task/Agent tool_use block on an assistant message.
  def extract_subagent_spawns(raw_event)
    message_data = raw_event["message"] || raw_event
    content = message_data["content"]
    return [] unless content.is_a?(Array)

    content.filter_map do |block|
      next unless block["type"] == "tool_use" && SUBAGENT_TOOL_NAMES.include?(block["name"])

      input = block["input"] || {}
      {
        tool_use_id: block["id"],
        subagent_type: input["subagent_type"],
        description: input["description"]
      }
    end
  end

  private

  # Per-line state shared by the type-specific builders.
  LineContext = Struct.new(
    :raw_event, :ts_string, :sort_time, :transcript_index, :subagents_by_tool_use_id,
    keyword_init: true
  ) do
    def message
      # A Claude Code line usually nests its payload under "message", but some
      # lines (e.g. a direct user message) carry role/content at the top level
      # with no envelope. Fall back to the raw line in that case, matching the
      # `raw_event["message"] || raw_event` convention used by the thinking/
      # tool-use extractors — otherwise the top-level content is silently
      # dropped and the message normalizes to empty content.
      m = raw_event["message"]
      m.is_a?(Hash) ? m : raw_event
    end

    def uuid
      uid = raw_event["uuid"]
      uid.present? ? uid : "cc-line-#{transcript_index || raw_event.object_id}"
    end

    def parent_uuid
      raw_event["parentUuid"]
    end

    # The raw line with base fields stripped, retained as provider_raw.
    def stripped_line
      raw_event.except("uuid", "parentUuid", "timestamp")
    end
  end

  # Build one event, applying id-suffix and parent-override conventions.
  def build_event(ctx, type:, event_order:, id_suffix: "", parent_id: :inherit,
    provider_raw: nil, **fields)
    id = id_suffix.empty? ? ctx.uuid : "#{ctx.uuid}:#{id_suffix}"
    resolved_parent = parent_id == :inherit ? ctx.parent_uuid : parent_id

    OpenTranscript.event(
      type: type,
      id: id,
      parent_id: resolved_parent,
      ts: ctx.ts_string,
      sort_time: ctx.sort_time,
      provider_raw: provider_raw,
      transcript_index: ctx.transcript_index,
      event_order: event_order,
      **fields
    )
  end

  def normalize_user_line(ctx)
    content = ctx.message["content"]
    tool_results = content.is_a?(Array) ? content.select { |b| b.is_a?(Hash) && b["type"] == "tool_result" } : []

    if tool_results.any?
      tool_results.each_with_index.map do |block, i|
        suffix = i.zero? ? "" : "toolresult:#{i}"
        build_event(
          ctx,
          type: OpenTranscript::Types::TOOL_RESULT,
          event_order: i,
          id_suffix: suffix,
          provider_raw: ctx.stripped_line,
          tool_call_id: block["tool_use_id"],
          output: tool_result_output(block["content"]),
          is_error: !!block["is_error"]
        )
      end
    else
      [
        build_event(
          ctx,
          type: OpenTranscript::Types::USER_MESSAGE,
          event_order: 0,
          provider_raw: ctx.stripped_line,
          content: message_content_parts(content)
        )
      ]
    end
  end

  def normalize_assistant_line(ctx)
    message = ctx.message
    content = message["content"]
    events = []
    order = 0

    am = build_event(
      ctx,
      type: OpenTranscript::Types::ASSISTANT_MESSAGE,
      event_order: order,
      provider_raw: ctx.stripped_line,
      content: assistant_text_parts(content),
      model: message["model"],
      stop_reason: message["stop_reason"],
      usage: OpenTranscript.usage_from(message["usage"]),
      cost_usd: nil
    )
    events << am
    am_id = am[:id]

    blocks = content.is_a?(Array) ? content : []

    thinking_blocks = blocks.select { |b| b.is_a?(Hash) && (b["type"] == "thinking" || b["type"] == "redacted_thinking") }
    thinking_blocks.each_with_index do |block, i|
      order += 1
      events << build_event(
        ctx,
        type: OpenTranscript::Types::THINKING,
        event_order: order,
        id_suffix: "thinking:#{i}",
        parent_id: am_id,
        text: block["thinking"] || block["text"],
        signature: block["signature"],
        redacted: block["type"] == "redacted_thinking" || !!block["redacted"]
      )
    end

    tool_use_blocks = blocks.select { |b| b.is_a?(Hash) && b["type"] == "tool_use" }
    tool_use_blocks.each_with_index do |block, i|
      tool_use_id = block["id"]
      input = block["input"] || {}

      order += 1
      events << build_event(
        ctx,
        type: OpenTranscript::Types::TOOL_CALL,
        event_order: order,
        id_suffix: "tool:#{i}",
        parent_id: am_id,
        tool_call_id: tool_use_id,
        tool_name: block["name"],
        arguments: input
      )

      next unless SUBAGENT_TOOL_NAMES.include?(block["name"])

      order += 1
      events << build_event(
        ctx,
        type: OpenTranscript::Types::SUBAGENT_SPAWN,
        event_order: order,
        id_suffix: "spawn:#{i}",
        parent_id: am_id,
        tool_call_id: tool_use_id,
        spawned_transcript_id: ctx.subagents_by_tool_use_id[tool_use_id],
        subagent_type: input["subagent_type"],
        description: input["description"],
        prompt: input["prompt"]
      )
    end

    events
  end

  def normalize_system_line(ctx)
    raw = ctx.raw_event
    sys_content = raw["content"]

    if raw["subtype"] == "compact_boundary"
      meta = raw["compactMetadata"].is_a?(Hash) ? raw["compactMetadata"] : {}
      trigger = meta["trigger"]
      trigger = nil unless %w[auto manual].include?(trigger)

      return [
        build_event(
          ctx,
          type: OpenTranscript::Types::COMPACTION,
          event_order: 0,
          provider_raw: ctx.stripped_line,
          summary: stringify_content(sys_content),
          first_kept_event_id: nil,
          tokens_before: meta["preTokens"],
          tokens_after: meta["postTokens"],
          trigger: trigger
        )
      ]
    end

    text = stringify_content(sys_content)
    if looks_like_error?(text)
      [
        build_event(
          ctx,
          type: OpenTranscript::Types::ERROR,
          event_order: 0,
          provider_raw: ctx.stripped_line,
          code: nil,
          message: text,
          recoverable: true,
          related_event_id: nil
        )
      ]
    else
      [
        build_event(
          ctx,
          type: OpenTranscript::Types::SYSTEM_EVENT,
          event_order: 0,
          subtype: "system",
          payload: ctx.stripped_line
        )
      ]
    end
  end

  def normalize_other_line(ctx)
    line_type = ctx.raw_event["type"]
    subtype = line_type.is_a?(String) && !line_type.empty? ? line_type : "unmapped"

    [
      build_event(
        ctx,
        type: OpenTranscript::Types::SYSTEM_EVENT,
        event_order: 0,
        subtype: subtype,
        payload: ctx.stripped_line
      )
    ]
  end

  # UserMessage content parts: text + image blocks, or a bare string.
  def message_content_parts(content)
    case content
    when String
      [ OpenTranscript.text_part(content) ]
    when Array
      OpenTranscript.content_parts_from_blocks(content)
    else
      []
    end
  end

  # AssistantMessage content is text-only per the spec.
  def assistant_text_parts(content)
    case content
    when String
      [ OpenTranscript.text_part(content) ]
    when Array
      content.filter_map do |block|
        next unless block.is_a?(Hash) && block["type"] == "text"

        OpenTranscript.text_part(block["text"])
      end
    else
      []
    end
  end

  # ToolResult output is a ContentPart[]: string -> one text part; array of
  # blocks -> mapped content parts (falling back to a text part for bare
  # strings); anything else -> empty.
  def tool_result_output(content)
    case content
    when String
      [ OpenTranscript.text_part(content) ]
    when Array
      content.filter_map do |block|
        if block.is_a?(Hash)
          part = OpenTranscript.content_parts_from_blocks([ block ]).first
          part || OpenTranscript.text_part(block.to_s)
        else
          OpenTranscript.text_part(block.to_s)
        end
      end
    else
      []
    end
  end

  def stringify_content(content)
    case content
    when String
      content
    when Array
      content.filter_map { |b| b["text"] if b.is_a?(Hash) }.join("\n").presence || ""
    when nil
      ""
    else
      content.to_s
    end
  end

  def looks_like_error?(text)
    return false if text.blank?

    text.start_with?("API Error") || text[0, 200].to_s.downcase.include?("error")
  end
end
