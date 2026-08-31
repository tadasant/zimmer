# frozen_string_literal: true

# Answers one question: has the runtime written a CONVERSATION for this session yet?
#
# The question matters because `metadata["runtime_started"]` does not answer it.
# That flag is set the moment Zimmer records a spawned pid — before the runtime
# has produced a line — so a process killed in its first seconds (an MCP server
# that failed to connect, a deploy, an OOM) leaves the flag true over a
# conversation that was never persisted. Anything that then issues a `--resume`
# against it is dead on arrival, and anything that reads the resulting instant
# exit as a completed turn parks the session with a blank transcript.
#
# Both stores are consulted and both must be without conversation before we
# conclude nothing was written:
#
#   * Zimmer's own `session.transcript`, filled by TranscriptPollerService.
#   * The runtime's transcript file on disk, located through the runtime-agnostic
#     TranscriptSource seam.
#
# Requiring both is deliberate. Zimmer's copy alone would call a session empty
# whenever polling is merely lagging or broken, and the runtime's file alone
# would miss a session whose clone has been recreated under it.
#
# ## Conversation, not bytes (#519)
#
# The presence test used to be "does either store hold a byte", and that is the
# question that wedged sessions permanently. Claude Code writes an `ai-title`
# record early and independently of any message, so a first job killed in its
# opening seconds leaves a ~126-byte transcript holding one record and no
# conversation. Under a byte test that file reads as a conversation, so every
# recovery path resumes into it — but the runtime disagrees with itself about
# the same file:
#
#     --session-id <id>  ->  "Session ID <id> is already in use."   (it exists)
#     --resume <id>      ->  "No conversation found with session ID" (it is empty)
#
# The id is simultaneously too present to create and too empty to resume, and
# the session burns its conflict budget and fails. So presence means at least one
# record the runtime's normalizer calls conversation — see
# TranscriptNormalizer#conversation_record?, which deny-lists the bookkeeping
# record types so an unrecognized one still counts as conversation.
module RuntimeConversationPresence
  module_function

  # @param session [Session]
  # @param working_directory [String, nil] the cwd the runtime was spawned from
  # @param file_system [FileSystemAdapter, nil] adapter for the on-disk lookup
  # @return [Boolean] true when either store holds a conversation
  def persisted?(session:, working_directory: nil, file_system: nil)
    return false if session.nil?
    return true if stored_conversation?(session)

    runtime_transcript_present?(session, working_directory, file_system)
  end

  # Zimmer's own copy, asked the same way and rescued the same way as the on-disk
  # half below. The rescue is not decoration: #handle_session_id_conflict turns any
  # raise out of this question into a terminal `failed`, which is the outcome the
  # whole of #519 is about — so a question that cannot be answered is answered
  # "present" rather than allowed to escape.
  def stored_conversation?(session)
    conversation?(session.transcript, session: session)
  rescue => e
    Rails.logger.warn(
      "[RuntimeConversationPresence] Could not inspect the stored transcript for " \
      "session #{session&.id}: #{e.message} — assuming a conversation exists"
    )
    true
  end

  # Errors are answered as "present" — the conservative direction. A lookup that
  # cannot run must not be read as proof the runtime wrote nothing, because every
  # caller treats that proof as licence to abandon the existing conversation.
  def runtime_transcript_present?(session, working_directory, file_system)
    return false if session.nil? || working_directory.blank?

    source = TranscriptRuntime.source_for(session, file_system: file_system)
    path = source.locate(session: session, working_directory: working_directory)
    return false if path.blank?

    conversation?(source.read_raw(path), session: session, source: source)
  rescue => e
    Rails.logger.warn(
      "[RuntimeConversationPresence] Could not inspect the runtime transcript for " \
      "session #{session&.id}: #{e.message} — assuming a conversation exists"
    )
    true
  end

  # Does a serialized transcript hold at least one conversation record?
  #
  # Public because the same question is asked of transcripts that are not on
  # disk yet: ForkSessionService asks it of the truncated transcript it is about
  # to hand a fork, so a fork of a stub session is not handed a transcript that
  # poisons its own freshly minted id.
  #
  # Scans lazily and stops at the first conversation record, so the common case
  # (a real transcript, whose first message is within the first few lines) does
  # not parse a large file to answer a yes/no.
  #
  # @param serialized [String, Array, nil] JSONL bytes, or the legacy array form
  # @param session [Session] whose runtime decides how records are read
  # @param source [TranscriptSource, nil] reuse an already-resolved source
  # @return [Boolean]
  def conversation?(serialized, session:, source: nil)
    return false if serialized.blank?
    # A stored shape neither the JSONL nor the legacy array reader understands is
    # content we cannot inspect, not content we can rule out.
    return true unless serialized.is_a?(String) || serialized.is_a?(Array)

    normalizer = TranscriptRuntime.normalizer_for(session)
    each_record(serialized, session: session, source: source) do |record|
      return true if normalizer.conversation_record?(record)
    end

    false
  end

  # Yields each record in a serialized transcript, one line at a time.
  #
  # A non-blank line the wire format cannot parse is yielded as an empty Hash,
  # which every normalizer's deny-list counts as conversation. That is the
  # conservative reading of the one case it covers: a last line caught
  # mid-flush, which is as likely to be a message as anything else.
  def each_record(serialized, session:, source: nil)
    return serialized.each { |record| yield record } if serialized.is_a?(Array)

    source ||= TranscriptRuntime.source_for(session)
    serialized.each_line do |line|
      next if line.strip.empty?

      record = source.parse_events(line).first
      yield(record || {})
    end
  end
  private_class_method :each_record
end
