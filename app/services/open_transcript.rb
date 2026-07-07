# frozen_string_literal: true

# OpenTranscript — Ruby representation of the OpenTranscripts v0.1 event model.
#
# This is a vendor-neutral, event-based transcript format. Both Zimmer runtimes
# (Claude Code and Codex) normalize their native transcript JSONL into a stream
# of OpenTranscripts events, and a single UI renderer (timeline_items/_item)
# dispatches on each event's `type`.
#
# The schema is mirrored from the source of truth in pulsemcp/ai-artifacts
# (open-transcripts spec + the `open_transcripts.py` / `cc_jsonl.py` reference
# converters). See docs/OPEN_TRANSCRIPTS.md for the vendored schema doc and the
# pointer back to the canonical definition.
#
# Representation choices for Zimmer:
# - Each event is a Ruby Hash with SYMBOL keys for the event's own fields
#   (:id, :ts, :type, ...). Nested structures that originate from parsed JSON
#   (ContentParts, tool arguments, provider_raw payloads) keep their STRING
#   keys, matching how they arrive from JSON.parse.
# - Events carry a few Zimmer-internal adornments alongside the spec fields:
#   :sort_time (a Time for stable ordering), :transcript_index (the source line
#   index, used by fork-from-here), and :event_order (intra-line fan-out order).
#   These are ignored by the spec but used by the renderer/controller.
# - Zimmer does NOT apply the reference converter's secret redaction. It renders raw
#   content exactly as it always has (documented fidelity note in the PR).
module OpenTranscript
  SCHEMA_VERSION = "0.1"

  # The nine OpenTranscripts v0.1 event type discriminators.
  module Types
    USER_MESSAGE = "UserMessage"
    ASSISTANT_MESSAGE = "AssistantMessage"
    THINKING = "Thinking"
    TOOL_CALL = "ToolCall"
    TOOL_RESULT = "ToolResult"
    SUBAGENT_SPAWN = "SubagentSpawn"
    COMPACTION = "Compaction"
    ERROR = "Error"
    SYSTEM_EVENT = "SystemEvent"

    ALL = [
      USER_MESSAGE, ASSISTANT_MESSAGE, THINKING, TOOL_CALL, TOOL_RESULT,
      SUBAGENT_SPAWN, COMPACTION, ERROR, SYSTEM_EVENT
    ].freeze
  end

  module_function

  # Build a ContentPart text node.
  def text_part(text)
    { "type" => "text", "text" => text.to_s }
  end

  # Build a ContentPart image node.
  def image_part(data:, mime_type:)
    { "type" => "image", "data" => data, "mime_type" => mime_type }
  end

  # Convert Claude/Anthropic content blocks into OpenTranscripts ContentParts.
  # Text blocks -> text parts; image blocks -> image parts (data from
  # source.data, mime_type from source.media_type || source.mime_type).
  # Unknown block types are dropped.
  def content_parts_from_blocks(blocks)
    return [] unless blocks.is_a?(Array)

    blocks.filter_map do |block|
      next unless block.is_a?(Hash)

      case block["type"]
      when "text"
        text_part(block["text"])
      when "image"
        source = block["source"] || {}
        image_part(
          data: source["data"],
          mime_type: source["media_type"] || source["mime_type"]
        )
      end
    end
  end

  # Build a Usage object from an Anthropic-style usage hash. Returns nil when
  # the input is not a hash (the spec omits `usage` unless it is a dict).
  def usage_from(raw)
    return nil unless raw.is_a?(Hash)

    {
      input_tokens: (raw["input_tokens"] || 0).to_i,
      output_tokens: (raw["output_tokens"] || 0).to_i,
      cache_read_tokens: (raw["cache_read_input_tokens"] || 0).to_i,
      cache_write_tokens: (raw["cache_creation_input_tokens"] || 0).to_i
    }
  end

  # Resolve a timestamp string into [rfc3339_string, Time].
  # Falls back to the provided fallback Time when the raw value is missing or
  # unparseable, so events never carry a null `ts` (a hard invariant).
  def resolve_ts(raw_ts, fallback_time)
    if raw_ts.is_a?(String) && !raw_ts.strip.empty?
      begin
        parsed = Time.parse(raw_ts)
        return [ raw_ts, parsed ]
      rescue ArgumentError, TypeError
        # fall through to fallback
      end
    end
    [ fallback_time.iso8601, fallback_time ]
  end

  # Assemble an event hash. Spec fields are symbol-keyed; `fields` carries the
  # per-type spec fields (e.g. content:, tool_name:). Adornments (:sort_time,
  # :transcript_index, :event_order) support rendering and ordering.
  def event(type:, id:, parent_id:, ts:, sort_time:, provider_raw: nil,
    transcript_index: nil, event_order: 0, **fields)
    {
      id: id,
      parent_id: parent_id,
      ts: ts,
      type: type,
      provider_raw: provider_raw,
      sort_time: sort_time,
      transcript_index: transcript_index,
      event_order: event_order
    }.merge(fields)
  end

  # True when a message event (UserMessage/AssistantMessage) carries no
  # renderable content: no non-blank text part and no image part. A Claude
  # assistant line made up solely of tool_use/thinking blocks normalizes into
  # exactly such an event — it is retained in the normalized stream because it
  # carries usage/model metadata and is the parent of the line's
  # Thinking/ToolCall/SubagentSpawn events, but it must not surface as a bare
  # row in the timeline. The single source of truth for "is this message worth
  # a row", shared by the renderer, the controller's filter/count predicate, and
  # the live broadcast path so every assembly point agrees. Non-message events
  # are never considered blank here (tool calls, thinking, results, etc. render
  # without an assistant body).
  def blank_message?(item)
    return false unless [ Types::USER_MESSAGE, Types::ASSISTANT_MESSAGE ].include?(item[:type])

    parts = item[:content]
    return true unless parts.is_a?(Array)

    parts.none? do |part|
      next false unless part.is_a?(Hash)

      case part["type"]
      when "text" then part["text"].to_s.strip.present?
      when "image" then true
      else false
      end
    end
  end

  # The single source of truth for mapping a timeline item to a DOM filter
  # category. Used by both timeline_items/_item.html.erb (data-filter-category)
  # and SessionsController#item_visible_for_filter? so server and client agree.
  #
  # Categories: "message", "tool-message", "queue-event", "regular-log",
  # "verbose-log".
  def filter_category(item)
    case item[:type]
    when Types::USER_MESSAGE, Types::ASSISTANT_MESSAGE, Types::COMPACTION, Types::ERROR
      "message"
    when Types::THINKING, Types::TOOL_CALL, Types::TOOL_RESULT, Types::SUBAGENT_SPAWN
      "tool-message"
    when Types::SYSTEM_EVENT
      item[:subtype] == "queue-operation" ? "queue-event" : "regular-log"
    when "mcp_log"
      "regular-log"
    when "log"
      item[:level] == "verbose" ? "verbose-log" : "regular-log"
    else
      "regular-log"
    end
  end

  # Assemble a full OpenTranscripts Transcript envelope from a flat list of
  # events (already Zimmer-internal hashes). Sorts events by ts ascending with a
  # stable tiebreak on (transcript_index, event_order), backfills nothing
  # (events always have a ts), and computes final_metrics. Primarily used by
  # tests and the invariant checks; the live UI consumes events directly.
  def build_transcript(events, agent_name:, vendor:, transcript_id: nil,
    cwd: nil, parent: nil, subagents: [], vendor_version: nil,
    unmapped_lines: [])
    sorted = sort_events(events)

    first_ts = sorted.first&.dig(:ts)
    last_ts = sorted.last&.dig(:ts)

    {
      schema_version: SCHEMA_VERSION,
      transcript_id: transcript_id,
      parent: parent,
      agent: { name: agent_name, version: vendor_version, model_default: nil },
      cwd: cwd,
      created_at: first_ts,
      ended_at: last_ts,
      events: sorted,
      subagents: subagents,
      final_metrics: final_metrics(sorted),
      provider: {
        vendor: vendor,
        vendor_version: vendor_version,
        raw: unmapped_lines.any? ? { "unmapped_lines" => unmapped_lines } : nil
      }
    }
  end

  # Stable sort by ts ascending, tiebreak on (transcript_index, event_order),
  # final tiebreak on insertion order so fan-out order within a line is kept.
  def sort_events(events)
    events.each_with_index.sort_by do |(ev, idx)|
      [ ev[:sort_time], ev[:transcript_index] || 0, ev[:event_order] || 0, idx ]
    end.map(&:first)
  end

  def final_metrics(sorted_events)
    tokens_in = 0
    tokens_out = 0
    sorted_events.each do |ev|
      usage = ev[:usage]
      next unless usage.is_a?(Hash)

      tokens_in += usage[:input_tokens].to_i
      tokens_out += usage[:output_tokens].to_i
    end

    wall_clock = 0.0
    first_time = sorted_events.first&.dig(:sort_time)
    last_time = sorted_events.last&.dig(:sort_time)
    if first_time && last_time
      wall_clock = (last_time - first_time).to_f
    end

    {
      total_tokens_in: tokens_in,
      total_tokens_out: tokens_out,
      cost_usd: nil,
      wall_clock_s: wall_clock
    }
  end

  # Validate the OpenTranscripts invariants on a Transcript envelope, recursing
  # into subagents. Raises ArgumentError on the first violation. Ported from the
  # reference `validate_transcript`.
  #
  # Invariants:
  #   1. Every event has a non-null ts, and events are sorted ascending by ts.
  #   2. Every event id is non-empty and unique within the transcript.
  #   3. SubagentSpawn.spawned_transcript_id is set <=> a subagent transcript
  #      with that transcript_id exists (bidirectional).
  def validate!(transcript)
    events = transcript[:events] || []

    # (1) non-null ts + ascending
    last = nil
    events.each do |ev|
      ts = ev[:ts]
      raise ArgumentError, "event #{ev[:id].inspect} has null ts" if ts.nil?

      if last && ev[:sort_time] < last
        raise ArgumentError, "events not sorted ascending by ts at #{ev[:id].inspect}"
      end
      last = ev[:sort_time]
    end

    # (2) ids non-empty + unique
    ids = events.map { |ev| ev[:id] }
    if ids.any? { |id| id.nil? || id.to_s.empty? }
      raise ArgumentError, "found event with empty id"
    end
    if ids.uniq.length != ids.length
      dupes = ids.tally.select { |_, c| c > 1 }.keys
      raise ArgumentError, "duplicate event ids: #{dupes.inspect}"
    end

    # (3) SubagentSpawn <-> subagents bijection
    spawn_ids = events
      .select { |ev| ev[:type] == Types::SUBAGENT_SPAWN }
      .map { |ev| ev[:spawned_transcript_id] }
      .compact
    subagent_ids = (transcript[:subagents] || []).map { |sub| sub[:transcript_id] }.compact

    missing_subagents = spawn_ids - subagent_ids
    unless missing_subagents.empty?
      raise ArgumentError, "SubagentSpawn references missing subagent transcript(s): #{missing_subagents.inspect}"
    end
    orphan_subagents = subagent_ids - spawn_ids
    unless orphan_subagents.empty?
      raise ArgumentError, "subagent transcript(s) with no spawn event: #{orphan_subagents.inspect}"
    end

    (transcript[:subagents] || []).each { |sub| validate!(sub) }

    true
  end
end
