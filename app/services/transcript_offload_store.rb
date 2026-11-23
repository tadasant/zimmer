# frozen_string_literal: true

require "zlib"
require "fileutils"

# Where a session's transcript lives once TranscriptRetentionJob has moved it out of
# Postgres: one gzip file per session, `<root>/<id % 1000>/<id>.jsonl.gz`.
#
# WHY ONE FILE PER SESSION, AND NOT THE TRANSCRIPT ARCHIVE ZIP
#
# TranscriptArchiveJob's `latest.zip` is rebuilt from the database every run, holds the
# whole corpus in one file, and is discarded and rebuilt from scratch when its sidecar
# says it is missing. That is fine for a convenience export and wrong for the only copy
# of a transcript: once the chunk rows are gone, a rebuild has nothing to rebuild from,
# and one bad rewrite of the zip would take every offloaded transcript with it. Here a
# write touches one session's file, through a temp file and a rename, and nothing ever
# rewrites a file except to replace it with a verified copy of the same transcript.
#
# WHERE
#
# Under the `zimmer_data` volume, beside the clones and the transcript archive, for the
# same reason the archive is there (TranscriptArchiveJob::ARCHIVE_SUBDIR): the writer
# runs in `worker` and readers (the session page, `get_session`) run in `web`, and that
# volume is the one both roles mount. Override with AGENT_TRANSCRIPT_OFFLOAD_DIR only
# onto a path both roles share.
#
# VERIFICATION
#
# `write` re-reads what it wrote and checks it against the digest the session row
# already holds before it returns; `read` checks it again on every read. A file that
# does not hash to the row's `transcript_digest` is never handed back as the transcript.
class TranscriptOffloadStore
  class Error < StandardError; end
  class Missing < Error; end
  class Corrupt < Error; end

  SUBDIR = "transcript_offload"
  DIR_ENV = "AGENT_TRANSCRIPT_OFFLOAD_DIR"
  SHARDS = 1000

  # A temp file this old belongs to a writer that was killed before its `ensure` ran.
  # A live write touches its temp continuously and takes seconds.
  TEMP_FILE_MIN_AGE = 1.hour
  TEMP_FILE_PATTERN = /\A\d+\.jsonl\.gz\.tmp-\h+\z/

  class << self
    # Resolved at call time, never memoized, so the env override and tests that stub
    # HOME are honoured without a restart. Namespaced per process under test, for the
    # reason SessionAttachmentStorage.base_dir gives: parallel workers hand out
    # colliding session ids.
    def root
      configured = ENV[DIR_ENV].presence
      base = configured ? File.expand_path(configured) : File.join(File.dirname(ClonesDirectory.base), SUBDIR)
      Rails.env.test? ? File.join(base, "test-worker-#{Process.pid}") : base
    end

    def path_for(session_id)
      id = Integer(session_id)
      File.join(root, (id % SHARDS).to_s, "#{id}.jsonl.gz")
    end

    def exist?(session_id) = File.file?(path_for(session_id))

    # Writes +content+ for +session_id+ and proves it: the file on disk is read back,
    # decompressed and hashed, and must equal +digest+ (SHA-256 hex of +content+).
    # Raises Corrupt, leaving any previous file in place, when it does not.
    def write(session_id, content, digest:)
      write_stream(session_id, digest: digest) { |out| out.write(content) }
    end

    # The streaming form of `write`: yields a writer to append the transcript to,
    # piece by piece, so the caller never has to hold the whole transcript in memory.
    # The digest is checked on the decompressed file, not on what was yielded, so it
    # proves what is actually on disk. Returns the compressed size in bytes.
    def write_stream(session_id, digest:)
      path = path_for(session_id)
      FileUtils.mkdir_p(File.dirname(path))
      temp = "#{path}.tmp-#{SecureRandom.hex(6)}"

      begin
        File.open(temp, "wb") do |file|
          gz = Zlib::GzipWriter.new(file, Zlib::BEST_COMPRESSION)
          yield gz
          gz.finish
          file.fsync
        end

        unless digest.present? && streamed_digest(temp) == digest
          raise Corrupt, "offloaded transcript #{temp} for session #{session_id} does not match its recorded digest"
        end

        File.rename(temp, path)
        fsync_dir(File.dirname(path))
      ensure
        File.delete(temp) if File.exist?(temp)
      end

      File.size(path)
    end

    # Removes a destroyed session's file. Called from Session#reclaim_session_directories
    # and nowhere else: while the session row exists its file may be the only copy.
    def delete(session_id)
      File.delete(path_for(session_id))
    rescue Errno::ENOENT
      nil
    end

    # Reclaims temps a SIGKILL left behind; `ensure` does not survive one. The pattern
    # cannot match a finished `<id>.jsonl.gz`. Returns how many it removed.
    def sweep_orphaned_temps(now: Time.current)
      return 0 unless File.directory?(root)

      Dir.children(root).sum do |shard|
        dir = File.join(root, shard)
        next 0 unless File.directory?(dir)

        Dir.children(dir).count do |entry|
          next false unless entry.match?(TEMP_FILE_PATTERN)

          path = File.join(dir, entry)
          next false if File.mtime(path) > now - TEMP_FILE_MIN_AGE

          File.delete(path)
          true
        rescue SystemCallError
          false
        end
      end
    end

    # The transcript text for +session_id+, verified against +digest+.
    def read(session_id, digest:)
      path = path_for(session_id)
      raise Missing, "no offloaded transcript for session #{session_id} at #{path}" unless File.file?(path)

      text = decompress(path)
      verify!(session_id, text, digest, path)
      text
    end

    private

    # SHA-256 of the decompressed file, read 1 MiB at a time.
    def streamed_digest(path)
      sha = Digest::SHA256.new
      Zlib::GzipReader.open(path) do |gz|
        while (piece = gz.read(1.megabyte))
          sha.update(piece)
        end
      end
      sha.hexdigest
    rescue Zlib::Error => e
      raise Corrupt, "offloaded transcript #{path} does not decompress: #{e.message}"
    end

    def decompress(path)
      text = Zlib::GzipReader.open(path) { |gz| gz.read }
      text.force_encoding(Encoding::UTF_8)
    rescue Zlib::Error => e
      raise Corrupt, "offloaded transcript #{path} does not decompress: #{e.message}"
    end

    def verify!(session_id, text, digest, path)
      return if digest.present? && Digest::SHA256.hexdigest(text) == digest

      raise Corrupt, "offloaded transcript #{path} for session #{session_id} does not match its recorded digest"
    end

    # The rename is only durable once the directory entry is.
    def fsync_dir(dir)
      File.open(dir) { |d| d.fsync }
    rescue SystemCallError
      nil
    end
  end
end
