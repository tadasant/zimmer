# Runtime-specific transcript semantics boundary.
#
# A TranscriptNormalizer turns a runtime's *raw events* (produced by a
# TranscriptSource) into OpenTranscripts v0.1 events — the vendor-neutral shape
# that the rest of the app consumes. It is the semantic layer of the transcript
# pipeline; the file/format layer (locating + reading + parsing bytes) belongs
# to TranscriptSource.
#
# Concrete implementations:
# - ClaudeTranscriptNormalizer (Claude Code JSONL message schema)
# - CodexTranscriptNormalizer (OpenAI Codex rollout JSONL)
#
# ---------------------------------------------------------------------------
# Output contract (the shape #normalize returns)
# ---------------------------------------------------------------------------
# #normalize returns an ARRAY of OpenTranscripts events (see OpenTranscript and
# docs/OPEN_TRANSCRIPTS.md). One source line may fan out into several events
# (e.g. an assistant line -> AssistantMessage + Thinking + ToolCall), or into
# none (bookkeeping lines that are not rendered). Each event is a symbol-keyed
# Hash carrying the spec fields (:id, :ts, :type, ...) plus AO render/order
# adornments (:sort_time, :transcript_index, :event_order). The single UI
# partial timeline_items/_item dispatches on each event's :type.
#
# A subagent-link descriptor (the shape #extract_subagent_links returns):
#
#   {
#     tool_use_id:     String,
#     agent_id:        String,            # runtime subagent id
#     status:          String | nil,
#     duration_ms:     Integer | nil,
#     total_tokens:    Integer | nil,
#     tool_use_count:  Integer | nil
#   }
class TranscriptNormalizer
  # Normalize a single raw event into zero or more OpenTranscripts events.
  #
  # Returns an Array (possibly empty). One source line may fan out into several
  # events, or into none (some runtimes emit bookkeeping records such as turn
  # boundaries or token-usage rows that are not rendered).
  #
  # @param raw_event [Hash] one raw event from a TranscriptSource
  # @param session [Session] used for the ts fallback (created_at)
  # @param transcript_index [Integer, nil] position in the stored transcript
  # @return [Array<Hash>] OpenTranscripts events (see OpenTranscript)
  def normalize(raw_event, session:, transcript_index: nil)
    raise NotImplementedError, "#{self.class}#normalize"
  end

  # Extract the runtime session id embedded in an event, if present.
  #
  # Claude and Codex both stamp their session UUID onto transcript records;
  # this lets a poller learn the id from the transcript when needed.
  #
  # @param raw_event [Hash] one raw event
  # @return [String, nil] the session id, or nil
  def extract_session_id(raw_event)
    raise NotImplementedError, "#{self.class}#extract_session_id"
  end

  # Whether this runtime mints its OWN session id that AO must learn from the
  # transcript (rather than honoring the id AO supplied at spawn).
  #
  # Codex ignores the AO-supplied id and generates its own rollout/thread UUID,
  # so the poller must capture it from the transcript for resume to target the
  # right rollout. Claude Code honors the AO-supplied `--session-id` / `--resume
  # <id>`, so its stored session id is already authoritative and must NEVER be
  # overwritten from transcript content — doing so corrupts forked sessions,
  # whose copied-from-source lines carry the SOURCE session's id (see
  # TranscriptPollerService#capture_runtime_session_id!).
  #
  # @return [Boolean]
  def mints_own_session_id?
    raise NotImplementedError, "#{self.class}#mints_own_session_id?"
  end

  # Extract subagent-link descriptors from a single event.
  #
  # Returns an empty array for runtimes without a subagent concept, and for
  # events that carry no subagent linkage.
  #
  # @param raw_event [Hash] one raw event
  # @return [Array<Hash>] subagent-link descriptors (see class doc)
  def extract_subagent_links(raw_event)
    raise NotImplementedError, "#{self.class}#extract_subagent_links"
  end

  # Extract subagent-spawn descriptors (the call that started a subagent) from
  # a single event, so a poller can correlate them with the links above.
  #
  # Returns an empty array for runtimes without a subagent concept.
  #
  # @param raw_event [Hash] one raw event
  # @return [Array<Hash>] { tool_use_id:, subagent_type:, description: }
  def extract_subagent_spawns(raw_event)
    raise NotImplementedError, "#{self.class}#extract_subagent_spawns"
  end
end
