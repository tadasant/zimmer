# frozen_string_literal: true

# Copies one session's transcript, and its subagents', to object storage and records it.
#
#   <env>/sessions/<yyyy>/<mm>/<session id>/transcript-<sha256>.jsonl.gz
#   <env>/sessions/<yyyy>/<mm>/<session id>/subagents/<agent id>-<sha256>.jsonl.gz
#   <env>/sessions/<yyyy>/<mm>/<session id>/manifest-<sha256>.json
#
# Readable without Zimmer: gunzip gives the JSONL as the runtime wrote it, and the
# manifest says what it is. `yyyy/mm` is when the session was created. Every name carries
# the SHA-256 of what it holds, so a transcript that changes gets a new object beside the
# old one, and two databases that share a bucket and a session id cannot collide.
#
# DELETES NOTHING, here or in the store. The TranscriptCopy row is written last, after
# every object has been read back from the store and hashed, so a row means the bytes are
# there. A failure before that leaves objects without a row, and the next run adopts them.
class TranscriptCopier
  SCHEMA = "zimmer.transcript/v1"

  # The chunks do not add up to what the row says. Not retried at that digest.
  class Mismatch < StandardError
    attr_reader :digest

    def initialize(message, digest:)
      @digest = digest
      super(message)
    end
  end
  # The transcript changed while it was being read. Retried next time.
  class Moved < StandardError; end

  # What a set of subagent transcripts was when it was copied, as SQL over
  # `subagent_transcripts` for one session. Equality, not "newer than": `updated_at` is
  # stamped before the write commits, so a write can land with a time already past.
  SUBAGENTS_FINGERPRINT_SQL = <<~SQL.squish
    COALESCE(md5(string_agg(st.id || '@' || to_char(st.updated_at, 'YYYYMMDDHH24MISSUS'), ',' ORDER BY st.id)), '')
  SQL

  # @param client [TranscriptStorage::GcsClient]
  def initialize(client)
    @client = client
  end

  # @return [TranscriptCopy, nil] nil when the session has no transcript to copy
  def copy(session_id)
    session = Session.find_by(id: session_id)
    return if session.nil? || !session.transcript_byte_size.positive? || session.transcript_digest.blank?

    @prefix = [ Rails.env, "sessions", session.created_at.utc.strftime("%Y/%m"), session.id ].join("/")
    transcript = copy_transcript(session)
    subagents = copy_subagents(session)
    manifest = copy_manifest(session, transcript, subagents)

    attributes = {
      session_id: session.id, manifest_generation: manifest[:generation],
      transcript_object: transcript[:object], transcript_generation: transcript[:generation],
      transcript_digest: session.transcript_digest, transcript_byte_size: session.transcript_byte_size,
      transcript_line_count: session.transcript_line_count, transcript_compressed_bytes: transcript[:compressed_bytes],
      conversation_byte_size: @conversation&.first, conversation_compressed_bytes: @conversation&.last,
      subagents: subagents, subagents_fingerprint: @subagents_fingerprint, verified_at: Time.current
    }
    record = TranscriptCopy.create_or_find_by!(bucket: @client.bucket, manifest_object: manifest[:object]) do |new_record|
      new_record.assign_attributes(attributes)
    end
    # Found rather than created: read back again just now, perhaps at another generation.
    record.update!(attributes) unless record.previously_new_record?
    record
  end

  private

  def copy_transcript(session)
    gzip_file do |gz, finish|
      write_chunks(session, gz)
      finish.call
      store("#{@prefix}/transcript-#{session.transcript_digest}.jsonl.gz", gz_path: gz.path_on_disk,
        digest: session.transcript_digest, metadata: { session_id: session.id, sha256: session.transcript_digest,
          bytes: session.transcript_byte_size, lines: session.transcript_line_count })
    end
  end

  # One chunk in memory at a time.
  def write_chunks(session, out)
    chunks = SessionTranscriptChunk.where(session_id: session.id)
    sha = Digest::SHA256.new
    bytes = 0
    conversation = ConversationMeter.new(session)
    chunks.order(:seq).pluck(:seq).each do |seq|
      content = SessionTranscriptChunk.uncached { chunks.where(seq: seq).pick(:content) }
      raise Moved, "chunk #{seq} vanished" if content.nil?

      sha.update(content)
      bytes += content.bytesize
      out.write(content)
      conversation.add(content)
    end
    @conversation = conversation.finish
    return if bytes == session.transcript_byte_size && sha.hexdigest == session.transcript_digest

    current = Session.where(id: session.id).pick(:transcript_digest)
    raise Moved, "transcript was rewritten" if current != session.transcript_digest

    raise Mismatch.new("chunks (#{bytes} bytes) do not match the row (#{session.transcript_byte_size} bytes)", digest: session.transcript_digest)
  end

  # One subagent in memory at a time.
  def copy_subagents(session)
    read = []
    entries = SubagentTranscript.where(session_id: session.id).order(:id).pluck(:id).filter_map do |id|
      subagent = SubagentTranscript.uncached { SubagentTranscript.find_by(id: id) }
      next if subagent.nil?

      read << "#{id}@#{subagent.updated_at.utc.strftime("%Y%m%d%H%M%S%6N")}"
      entry = { agent_id: subagent.agent_id, type: subagent.subagent_type, description: subagent.description,
                status: subagent.status, tool_use_id: subagent.tool_use_id, filename: subagent.filename }
      text = subagent.transcript.to_s
      next entry if text.empty?

      digest = Digest::SHA256.hexdigest(text)
      stored = gzip_file do |gz, finish|
        gz.write(text)
        finish.call
        store("#{@prefix}/subagents/#{subagent.agent_id.to_s.gsub(/[^A-Za-z0-9_-]/, "_")}-#{digest}.jsonl.gz",
          gz_path: gz.path_on_disk, digest: digest, metadata: { session_id: session.id, sha256: digest, bytes: text.bytesize })
      end
      entry.merge(stored).merge(sha256: digest, bytes: text.bytesize)
    end
    @subagents_fingerprint = read.empty? ? "" : Digest::MD5.hexdigest(read.join(","))
    entries.map(&:stringify_keys)
  end

  # No timestamp of the copy in it, so copying the same thing twice makes one object.
  def copy_manifest(session, transcript, subagents)
    body = JSON.pretty_generate(
      schema: SCHEMA,
      session: {
        id: session.id, slug: session.slug, title: session.title, agent_runtime: session.agent_runtime,
        runtime_session_id: session.session_id, git_root: session.git_root, branch: session.branch,
        created_at: session.created_at&.utc&.iso8601, archived_at: session.archived_at&.utc&.iso8601
      },
      transcript: transcript.merge(
        sha256: session.transcript_digest, bytes: session.transcript_byte_size, lines: session.transcript_line_count
      ),
      subagents: subagents
    )
    digest = Digest::SHA256.hexdigest(body)
    Tempfile.create([ "transcript-manifest", ".json" ]) do |file|
      file.write(body)
      file.flush
      store("#{@prefix}/manifest-#{digest}.json", gz_path: file.path, digest: digest, gunzip: false,
        content_type: "application/json", metadata: { session_id: session.id, sha256: digest })
    end
  end

  # Uploads, then reads the object back and hashes what came out.
  def store(name, gz_path:, digest:, metadata:, gunzip: true, content_type: "application/gzip")
    generation = @client.create(name, path: gz_path, content_type: content_type, metadata: metadata)
    stored_digest, size = @client.digest(name, generation: generation, gunzip: gunzip)
    raise TranscriptStorage::VerificationFailed, "#{name} does not hold what was sent" unless stored_digest == digest

    { object: name, generation: generation, compressed_bytes: size }
  end

  # Yields a gzip writer over a temp file, and a lambda that finishes it. A fixed mtime
  # keeps the bytes the same for the same input.
  def gzip_file
    Tempfile.create([ "transcript-copy", ".gz" ], binmode: true) do |file|
      gz = Zlib::GzipWriter.new(file)
      gz.mtime = 1
      gz.define_singleton_method(:path_on_disk) { file.path }
      yield gz, -> { gz.finish && file.flush }
    ensure
      gz&.close unless gz&.closed?
    end
  end

  # How big the conversation alone is, raw and compressed. A measurement only: a line it
  # cannot render must not stop a transcript being copied.
  class ConversationMeter
    def initialize(session)
      @text = SessionConversationText.new(session)
      @deflate = Zlib::Deflate.new
      @raw = 0
      @compressed = 0
      @index = 0
    rescue StandardError
      @text = nil
    end

    def add(content)
      return if @text.nil?

      content.each_line do |line|
        text = @text.line(line, @index)
        @index += 1
        next if text.empty?

        @raw += text.bytesize
        @compressed += @deflate.deflate(text).bytesize
      end
    rescue StandardError
      @text = nil
    end

    # @return [Array(Integer, Integer), nil]
    def finish
      rest = @deflate&.finish
      @deflate&.close
      @text && [ @raw, @compressed + rest.bytesize ]
    end
  end
end
