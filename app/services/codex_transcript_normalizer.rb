# TranscriptNormalizer for the OpenAI Codex runtime.
#
# Maps Codex's rollout JSONL onto OpenTranscripts v0.1 events (see OpenTranscript
# and https://docs.zimmer.tadasant.com/sessions/transcripts/). Each rollout line is wrapped:
#
#   { "timestamp": "2026-05-29T21:39:15.456Z",
#     "type": "response_item" | "event_msg" | "session_meta" | "turn_context" | "compacted",
#     "payload": { ... } }
#
# Source of truth: the `response_item` lines carry the model conversation
# history — user/assistant messages, function (tool) calls, tool outputs, and
# reasoning. The `event_msg` lines (e.g. `agent_message`, `user_message`,
# `token_count`, `task_started`/`task_complete`) are UI-side duplicates or
# bookkeeping, so we normalize ONLY `response_item` and `compacted` lines and
# skip the rest. Normalizing both would render every assistant/user turn twice.
#
# Codex events map onto OpenTranscripts events as:
# - message (role assistant) -> AssistantMessage
# - message (role user)      -> UserMessage
# - function_call / local_shell_call / custom_tool_call -> ToolCall
# - function_call_output / custom_tool_call_output      -> ToolResult
# - reasoning -> Thinking
# - compacted -> Compaction
#
# Codex has no subagent concept, so the subagent extractors always return [] and
# no SubagentSpawn events are emitted.
class CodexTranscriptNormalizer < TranscriptNormalizer
  # @see TranscriptNormalizer#normalize
  #
  # Returns an Array of OpenTranscripts events (empty for lines that are not
  # rendered — session_meta, turn_context, event_msg, and unhandled
  # response_item subtypes).
  def normalize(raw_event, session:, transcript_index: nil)
    ts_string, sort_time = OpenTranscript.resolve_ts(raw_event["timestamp"], session.created_at)
    ctx = {
      raw_event: raw_event,
      ts_string: ts_string,
      sort_time: sort_time,
      transcript_index: transcript_index
    }

    event = case raw_event["type"]
    when "response_item"
      build_response_item_event(raw_event["payload"], ctx)
    when "compacted"
      build_compacted_event(raw_event["payload"], ctx)
    end

    event ? [ event ] : []
  end

  # @see TranscriptNormalizer#extract_session_id
  #
  # The session UUID lives on the `session_meta` line's payload `id`.
  def extract_session_id(raw_event)
    return nil unless raw_event["type"] == "session_meta"

    raw_event.dig("payload", "id")
  end

  # @see TranscriptNormalizer#mints_own_session_id?
  #
  # Codex ignores the Zimmer-supplied session id and generates its own rollout/thread
  # UUID, emitted on the `session_meta` line. The poller must capture that UUID
  # so `codex exec resume <uuid>` targets the right rollout.
  def mints_own_session_id?
    true
  end

  # @see TranscriptNormalizer#extract_subagent_links
  #
  # Codex has no subagent concept.
  def extract_subagent_links(raw_event)
    []
  end

  # @see TranscriptNormalizer#extract_subagent_spawns
  #
  # Codex has no subagent concept.
  def extract_subagent_spawns(raw_event)
    []
  end

  private

  def event_id(ctx, suffix = "")
    base = ctx[:transcript_index] ? "codex-#{ctx[:transcript_index]}" : "codex-#{ctx[:raw_event].object_id}"
    suffix.empty? ? base : "#{base}:#{suffix}"
  end

  def base_event(ctx, type:, provider_raw: nil, **fields)
    OpenTranscript.event(
      type: type,
      id: event_id(ctx),
      parent_id: nil,
      ts: ctx[:ts_string],
      sort_time: ctx[:sort_time],
      provider_raw: provider_raw,
      transcript_index: ctx[:transcript_index],
      event_order: 0,
      **fields
    )
  end

  def build_response_item_event(payload, ctx)
    return nil unless payload.is_a?(Hash)

    case payload["type"]
    when "message"
      build_message_event(payload, ctx)
    when "function_call"
      tool_call_event(ctx, call_id: payload["call_id"], name: payload["name"], arguments: parse_arguments(payload["arguments"]))
    when "local_shell_call"
      tool_call_event(ctx, call_id: payload["call_id"], name: "shell", arguments: payload["action"] || {})
    when "custom_tool_call"
      tool_call_event(ctx, call_id: payload["call_id"], name: payload["name"], arguments: { "input" => payload["input"] })
    when "function_call_output", "custom_tool_call_output"
      tool_result_event(ctx, call_id: payload["call_id"], output: payload["output"])
    when "reasoning"
      build_reasoning_event(payload, ctx)
    end
    # Unhandled response_item types (web_search_call, image_generation_call,
    # tool_search_call, ...) return nil and are not surfaced.
  end

  # A user/assistant text message. Codex content blocks use `output_text`
  # (assistant) and `input_text` (user); both fold into a text ContentPart.
  # `input_image` blocks fold into an image ContentPart.
  def build_message_event(payload, ctx)
    content = payload["content"]
    return nil unless content.is_a?(Array)

    parts = content.filter_map { |block| normalize_content_part(block) }
    return nil if parts.empty?

    if payload["role"] == "user"
      base_event(ctx, type: OpenTranscript::Types::USER_MESSAGE, provider_raw: payload, content: parts)
    else
      base_event(
        ctx,
        type: OpenTranscript::Types::ASSISTANT_MESSAGE,
        provider_raw: payload,
        content: parts.select { |p| p["type"] == "text" },
        model: nil,
        stop_reason: nil,
        usage: nil,
        cost_usd: nil
      )
    end
  end

  def normalize_content_part(block)
    return nil unless block.is_a?(Hash)

    case block["type"]
    when "output_text", "input_text", "text"
      text = block["text"]
      text.present? ? OpenTranscript.text_part(text) : nil
    when "input_image"
      OpenTranscript.image_part(data: block["image_url"], mime_type: nil)
    end
  end

  def tool_call_event(ctx, call_id:, name:, arguments:)
    base_event(
      ctx,
      type: OpenTranscript::Types::TOOL_CALL,
      provider_raw: ctx[:raw_event]["payload"],
      tool_call_id: call_id,
      tool_name: name,
      arguments: arguments
    )
  end

  def tool_result_event(ctx, call_id:, output:)
    base_event(
      ctx,
      type: OpenTranscript::Types::TOOL_RESULT,
      provider_raw: ctx[:raw_event]["payload"],
      tool_call_id: call_id,
      output: normalize_tool_output(output),
      is_error: false
    )
  end

  # Codex serializes a tool output as either a bare String or an array of
  # content items ({ "type": ..., "text": ... }). Map onto ContentPart[].
  def normalize_tool_output(output)
    case output
    when String
      [ OpenTranscript.text_part(output) ]
    when Array
      output.filter_map { |item| OpenTranscript.text_part(item["text"]) if item.is_a?(Hash) && item["text"].present? }
    else
      []
    end
  end

  # Codex reasoning carries a `summary` array of { type: "summary_text", text }
  # and an optional `content` array of reasoning text. Render whichever text is
  # present as a Thinking event; skip when there is nothing to show.
  def build_reasoning_event(payload, ctx)
    text = reasoning_text(payload["summary"])
    text = reasoning_text(payload["content"]) if text.blank?
    return nil if text.blank?

    base_event(
      ctx,
      type: OpenTranscript::Types::THINKING,
      provider_raw: payload,
      text: text,
      signature: nil,
      redacted: false
    )
  end

  def reasoning_text(blocks)
    return nil unless blocks.is_a?(Array)

    blocks.filter_map { |b| b["text"] if b.is_a?(Hash) }.join("\n\n").presence
  end

  # A context-compaction marker -> Compaction event so the boundary is visible.
  def build_compacted_event(payload, ctx)
    return nil unless payload.is_a?(Hash)

    message = payload["message"]
    return nil if message.blank?

    base_event(
      ctx,
      type: OpenTranscript::Types::COMPACTION,
      provider_raw: payload,
      summary: message.to_s,
      first_kept_event_id: nil,
      tokens_before: nil,
      tokens_after: nil,
      trigger: nil
    )
  end

  # The Codex `function_call` arguments field is a JSON-encoded String. Parse it
  # into a Hash; fall back to a single-key Hash when it is not a valid JSON
  # object.
  def parse_arguments(arguments)
    return {} if arguments.blank?
    return arguments if arguments.is_a?(Hash)

    parsed = JSON.parse(arguments)
    parsed.is_a?(Hash) ? parsed : { "arguments" => parsed }
  rescue JSON::ParserError
    { "arguments" => arguments }
  end
end
