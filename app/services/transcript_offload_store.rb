# frozen_string_literal: true

require "zlib"
require "fileutils"

# Where a session's transcript lives once TranscriptRetentionJob has moved it out of
# Postgres: one gzip file per session,
# `<base>/<store id>/<database location>/<id % 1000>/<id>-<sha256>.jsonl.gz`. The digest
# is in the name, so a write can only ever replace identical bytes: an overlapping run, a
# re-offload or a database restored to an earlier point cannot overwrite another version.
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
# WHOSE FILES
#
# Once chunks are deleted a file here is the only copy of a transcript, and the volume is
# shared by more than one database: an agent session on the production worker can boot a
# development server whose `~/.zimmer` is production's, and whose session ids start at 1.
# So no path depends on a session id alone:
#
#   store id           A UUID kept in the database's own `ar_internal_metadata`, created on
#                      the first write. Another database has another id, so it can neither
#                      see, overwrite nor delete these files.
#   database location  A hash of the host, port and name this process is connected to. A
#                      copy of a database carries its store id with it; the copy is
#                      reached at another location, so it writes and deletes elsewhere.
#
# Writes, deletes and sweeps touch only this process's own directory. Reads try it first
# and then the other locations under the same store id, so moving the database to another
# host does not strand its files. Every read is checked against the row's digest, so a
# fallback can only return the exact bytes that row vouches for.
#
# The id is stored with the environment that created it, once. A process in any other
# environment writes, sweeps and deletes nothing (Refused): a development process connected
# to production must not put production's transcripts anywhere. Also Refused: creating an id
# when sessions are already marked offloaded (the id was lost), and writing when they are
# but the store's directory is absent (the volume is not mounted, or is another machine's).
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
  class Refused < Error; end

  STORE_ID_KEY = "transcript_offload_store_id"
  STORE_ENVIRONMENT_KEY = "transcript_offload_store_environment"
  STORE_ID_PATTERN = /\A\h{8}(-\h{4}){3}-\h{12}\z/

  SUBDIR = "transcript_offload"
  DIR_ENV = "AGENT_TRANSCRIPT_OFFLOAD_DIR"
  SHARDS = 1000

  # A temp file this old belongs to a writer that was killed before its `ensure` ran.
  # A live write touches its temp continuously and takes seconds.
  TEMP_FILE_MIN_AGE = 1.hour
  TEMP_FILE_PATTERN = /\A\d+-\h{64}\.jsonl\.gz\.tmp-\h+\z/

  class << self
    # The directory every store shares. Resolved at call time, never memoized, so the env
    # override and tests that stub HOME are honoured without a restart.
    def base
      configured = ENV[DIR_ENV].presence
      configured ? File.expand_path(configured) : File.join(File.dirname(ClonesDirectory.base), SUBDIR)
    end

    # This process's own directory, or nil while its database has no store id, which is
    # also while it has never offloaded anything.
    def root
      id = store_id
      id && File.join(base, id, database_location)
    end

    # Claims and returns this process's own directory. Raises Refused when this process may
    # not write here. Call outside a transaction: the id has to outlive a rollback.
    def prepare!
      refuse_foreign_environment!
      if Session.where.not(transcript_offloaded_at: nil).exists?
        raise Refused, "sessions are marked offloaded but this database has no transcript store id" unless store_id
        raise Refused, "sessions are marked offloaded but #{store_dir} is absent; is the volume mounted?" unless File.directory?(store_dir)
      end
      create_store_id unless store_id
      root.tap { |dir| FileUtils.mkdir_p(dir) }
    end

    # Why this process may not write, or nil. For the health report.
    def refusal
      refuse_foreign_environment!
      nil
    rescue Refused => e
      e.message
    end

    # Every version of +session_id+'s transcript under this database's store id, own
    # location first.
    def paths_for(session_id)
      id = Integer(session_id)
      directories.flat_map { |dir| Dir.glob(File.join(shard_dir(dir, id), "#{id}-*.jsonl.gz")).sort }
    rescue Refused
      []
    end

    def exist?(session_id) = paths_for(session_id).any?

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
      path = version_path(prepare!, session_id, digest)
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
        # Shard, location, store, base and its parent: the chunk delete that follows
        # commits on another machine, so none of these may still be only in page cache.
        dir = File.dirname(path)
        5.times do
          fsync_dir(dir)
          dir = File.dirname(dir)
        end
      ensure
        File.delete(temp) if File.exist?(temp)
      end

      File.size(path)
    end

    # Removes a destroyed session's file. Called from Session#reclaim_session_directories
    # and from the job for a session destroyed mid-copy: while the row exists its file may
    # be the only copy. Never touches a directory other than this process's own.
    # Files an earlier database location left are not reached, and stay.
    def delete(session_id)
      own = root
      return if own.nil?

      refuse_foreign_environment!
      id = Integer(session_id)
      Dir.glob(File.join(shard_dir(own, id), "#{id}-*.jsonl.gz")).each { |path| FileUtils.rm_f(path) }
      nil
    end

    # Reclaims temps a SIGKILL left behind; `ensure` does not survive one. The pattern
    # cannot match a finished `<id>.jsonl.gz`. Returns how many it removed.
    def sweep_orphaned_temps(now: Time.current)
      own = root
      return 0 unless own && File.directory?(own)

      refuse_foreign_environment!

      Dir.children(own).sum do |shard|
        dir = File.join(own, shard)
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
      failure = Missing.new("no offloaded transcript for session #{session_id} under #{base}")
      directories.each do |dir|
        path = version_path(dir, session_id, digest)
        next unless File.file?(path)

        text = decompress(path)
        verify!(session_id, text, digest, path)
        return text
      rescue Corrupt, SystemCallError => e
        failure = e
      end
      raise failure
    end

    private

    def shard_dir(dir, id) = File.join(dir, (id % SHARDS).to_s)

    def version_path(dir, session_id, digest)
      raise Corrupt, "session #{session_id} has no transcript digest" unless digest.to_s.match?(/\A\h{64}\z/)

      id = Integer(session_id)
      File.join(shard_dir(dir, id), "#{id}-#{digest}.jsonl.gz")
    end

    def store_dir = File.join(base, store_id)

    # This process's own directory first, then the other locations of the same store.
    def directories
      own = root
      return [] if own.nil?

      siblings = File.directory?(store_dir) ? Dir.children(store_dir).sort.map { |name| File.join(store_dir, name) } : []
      [ own, *siblings ].uniq
    end

    def metadata = ActiveRecord::Base.connection_pool.internal_metadata

    # Validated because it becomes a path segment.
    def store_id
      id = metadata[STORE_ID_KEY]
      raise Refused, "malformed transcript store id in the database" if id && !id.match?(STORE_ID_PATTERN)

      id
    end

    # Both rows in one statement, ON CONFLICT DO NOTHING. Two processes may race; the first
    # insert wins and both read that one.
    def create_store_id
      table = metadata.table_name
      rows = Class.new(ActiveRecord::Base) { self.table_name = table }
      rows.insert_all(
        { STORE_ID_KEY => SecureRandom.uuid, STORE_ENVIRONMENT_KEY => Rails.env.to_s }
          .map { |key, value| { key: key, value: value, created_at: Time.current, updated_at: Time.current } }
      )
      raise Refused, "could not record a transcript store id" if store_id.nil?
    end

    def database_location
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      Digest::SHA256.hexdigest(config.values_at(:host, :port, :database).join("|").downcase).first(16)
    end

    # The environment that created the store, or before there is one, the one Rails
    # recorded for the database. Every migration rewrites Rails's; nothing rewrites ours.
    def refuse_foreign_environment!
      recorded = metadata[STORE_ENVIRONMENT_KEY] || metadata[:environment]
      return if recorded == Rails.env.to_s

      raise Refused, "database belongs to #{recorded.inspect}, this process is #{Rails.env.inspect}; not touching offloaded transcripts"
    end

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

    # The rename is only durable once the directory entry is. A filesystem that does not
    # support fsync on a directory is tolerated; an I/O error is not.
    def fsync_dir(dir)
      File.open(dir) { |d| d.fsync }
    rescue Errno::EINVAL, Errno::ENOTSUP
      nil
    end
  end
end
