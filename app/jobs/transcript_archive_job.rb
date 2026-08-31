# frozen_string_literal: true

require "zip"
require "fileutils"

# Periodic job that incrementally builds/updates a zip file containing all session transcripts.
#
# Runs every 10 minutes. On each run, it:
# 1. Loads metadata from the previous run to identify already-archived sessions
# 2. Queries all sessions with transcripts, finding new or changed ones
# 3. Updates at most MAX_SESSIONS_PER_RUN changed entries in the zip file, one session
#    resident at a time, deferring any remainder to the next tick
# 4. Writes atomically via temp file + rename
#
# Steps 3 and 4 are load-bearing rather than incidental, and #719 is why. A transcript
# is a single large payload, so the job's peak memory is decided entirely by how many of
# them it holds at once; it used to hold every changed session simultaneously, which on
# a corpus that has never been archived means all of them. Every method below that
# touches a transcript takes session *ids* and loads rows one at a time, and the cap
# guarantees each run reaches step 4 and records its progress. Handing any of them a
# collection of Session objects reintroduces the OOM.
#
# The resulting zip is served by Api::V1::TranscriptArchivesController and located
# for callers by the get_transcript_archive MCP tool. Both of those readers run in a
# different container from this writer, which is why ARCHIVE_SUBDIR below resolves
# under the shared ~/.zimmer volume rather than under Rails.root. TranscriptArchiveStatus
# is the one place that answers "is there an archive, and how old is it".
#
class TranscriptArchiveJob < ApplicationJob
  include DatabaseRetry
  queue_as :default
  include SingletonSweep

  # Subdirectory, under the durable ~/.zimmer root, that holds the archive.
  #
  # NOT Rails.root/storage. The writer is this job, which runs in the `worker`
  # container (production sets GoodJob execution_mode = :external, and GoodJob only
  # starts a cron capsule in a webserver process running :async/:async_server — so
  # cron fires in `worker` alone). Every reader is an HTTP route served by Puma in
  # the `web` container: Api::V1::TranscriptArchivesController and the
  # get_transcript_archive MCP tool. `Rails.root/storage` is a per-container overlay
  # layer that no deploy config mounts, so for as long as the archive lived there the
  # worker wrote into its own layer and the web container read its own, empty one —
  # get_transcript_archive could not succeed in production however well the job ran
  # (#714). The same fact destroyed the worker's own copy on every deploy, which made
  # the incremental job re-treat the whole corpus as changed on its next run (#495).
  #
  # ~/.zimmer is the `zimmer_data` named volume, mounted at the same path in BOTH
  # roles, so it is both shared and deploy-durable. This is the same resolution
  # SessionAttachmentStorage uses, for the same reason and with the same caveat:
  # override it with AGENT_TRANSCRIPT_ARCHIVE_DIR only onto a path that both roles
  # share, or the reader stops seeing the writer again.
  ARCHIVE_SUBDIR = "transcript_archives"
  ARCHIVE_DIR_ENV = "AGENT_TRANSCRIPT_ARCHIVE_DIR"
  BATCH_SIZE = 50

  # How many changed sessions one run will archive before deferring the rest to the
  # next tick.
  #
  # This is what makes the job converge rather than restart. A run archives a slice
  # and then writes its metadata, so the sessions it did are recorded as archived even
  # though the corpus is not finished. Without a cap, the first run against a corpus
  # that has never been archived tries to do all of it, and anything that interrupts it
  # — an OOM kill, a deploy, a worker restart — throws the whole run away, because
  # metadata is only written at the end. The next tick then starts from zero and
  # interrupts at the same place. That loop is #495, and on production it ran every ten
  # minutes indefinitely.
  #
  # Steady state is a handful of changed sessions per tick, so the cap is invisible
  # there; it only binds while catching up.
  MAX_SESSIONS_PER_RUN = 250

  # An archive older than this is still served, but is reported as stale rather
  # than presented as current. Six cron ticks — long enough that a single slow or
  # skipped run is not called a fault, short enough that a job which has stopped
  # succeeding is visible before anyone acts on the data.
  STALE_AFTER = 1.hour

  class << self
    # Resolved at call time (never memoized) so tests that stub HOME and ops that
    # set the override are both honored without a process restart.
    def archive_dir
      configured = ENV[ARCHIVE_DIR_ENV].presence
      return Pathname.new(File.expand_path(configured)) if configured

      Pathname.new(File.join(File.dirname(ClonesDirectory.base), ARCHIVE_SUBDIR))
    end

    def archive_path = archive_dir.join("latest.zip")

    def metadata_path = archive_dir.join("latest_metadata.json")
  end

  def perform
    FileUtils.mkdir_p(archive_dir)

    previous_metadata = load_metadata
    previous_sessions = previous_metadata["sessions"] || {}

    # Find all sessions with transcripts (any status)
    session_ids_to_archive = Set.new
    removed_session_ids = Set.new(previous_sessions.keys)

    with_db_retry do
      transcript_session_markers.find_each(batch_size: BATCH_SIZE) do |session_metadata|
        session_id = session_metadata.id.to_s
        removed_session_ids.delete(session_id)

        last_updated = session_metadata.updated_at.iso8601(6)
        previously_archived_at = previous_sessions[session_id]

        # Only include if new or changed
        if previously_archived_at.nil? || previously_archived_at != last_updated
          session_ids_to_archive << session_metadata.id
        end
      end
    end

    # Also check for sessions with subagent transcripts but no main transcript
    with_db_retry do
      subagent_session_ids = SubagentTranscript.distinct.pluck(:session_id)
      candidate_ids = subagent_session_ids.reject do |sid|
        session_id = sid.to_s
        (previous_sessions.key?(session_id) && !removed_session_ids.include?(session_id)) ||
          session_ids_to_archive.include?(sid) # already queued from the main transcript check
      end

      # One `pluck` for existence rather than `Session.find_by` per id. The old form
      # instantiated a full Session — transcript column and all — for every session
      # with a subagent transcript, just to ask whether the row was still there.
      Session.where(id: candidate_ids).pluck(:id).each do |sid|
        removed_session_ids.delete(sid.to_s)
        session_ids_to_archive << sid
      end
    end

    # Ordered so a capped run is a prefix and the next run resumes after it, rather
    # than re-picking an arbitrary subset of the same backlog.
    changed_ids = session_ids_to_archive.to_a.sort
    deferred_count = [ changed_ids.size - max_sessions_per_run, 0 ].max
    changed_ids = changed_ids.first(max_sessions_per_run)

    if changed_ids.empty? && removed_session_ids.empty? && File.exist?(archive_path)
      Rails.logger.info "[TranscriptArchiveJob] No changes detected, skipping rebuild"
      return
    end

    # WARN, not INFO, and deliberately so: production ships only WARN and above to
    # VictoriaLogs, so an INFO line here would be invisible on the one deployment that
    # needs it. A backlog is abnormal and self-clearing — this goes quiet once the
    # corpus is caught up — so it is not standing noise.
    if deferred_count.positive?
      Rails.logger.warn "[TranscriptArchiveJob] archiving #{changed_ids.size} changed sessions this run; " \
                        "#{deferred_count} deferred to the next tick"
    end

    build_archive(changed_ids, previous_sessions, removed_session_ids)
  end

  # Path accessors — instance methods so tests can stub them for isolation
  def archive_dir = self.class.archive_dir

  def archive_path = self.class.archive_path

  def metadata_path = self.class.metadata_path

  # Instance method for the same reason as the paths above — so a test can shrink the
  # cap to a couple of sessions instead of having to create MAX_SESSIONS_PER_RUN of them
  # to reach the deferral path.
  def max_sessions_per_run = MAX_SESSIONS_PER_RUN

  private

  def transcript_session_markers
    Session.where.not(transcript: nil).select(:id, :updated_at)
  end

  def load_metadata
    return {} unless File.exist?(metadata_path)

    JSON.parse(File.read(metadata_path))
  rescue JSON::ParserError => e
    Rails.logger.error "[TranscriptArchiveJob] Failed to parse metadata: #{e.message}"
    {}
  end

  def build_archive(changed_ids, previous_sessions, removed_session_ids)
    temp_path = archive_dir.join("latest_#{SecureRandom.hex(8)}.zip.tmp")
    all_sessions_metadata = previous_sessions.dup

    # Remove deleted sessions from tracking
    removed_session_ids.each { |id| all_sessions_metadata.delete(id) }

    begin
      if File.exist?(archive_path) && removed_session_ids.empty?
        # Copy existing archive and update incrementally
        FileUtils.cp(archive_path, temp_path)
        update_zip(temp_path, changed_ids, all_sessions_metadata)
      else
        # Build from scratch (first run or sessions were removed)
        build_full_zip(temp_path, changed_ids, previous_sessions, all_sessions_metadata, removed_session_ids)
      end

      # Write manifest
      write_manifest(temp_path, all_sessions_metadata)

      # Atomic rename
      FileUtils.mv(temp_path, archive_path)

      # Write metadata
      write_metadata(all_sessions_metadata)

      Rails.logger.info "[TranscriptArchiveJob] Archive updated: #{all_sessions_metadata.size} sessions, " \
                        "#{changed_ids.size} changed, #{removed_session_ids.size} removed, " \
                        "#{File.size(archive_path)} bytes"
    ensure
      File.delete(temp_path) if File.exist?(temp_path)
    end
  end

  # Yields each changed session, one resident at a time.
  #
  # This is the whole of #719. The caller used to be handed
  # `Session.where(id: changed_ids).to_a`, which held every changed session — each with
  # its full `transcript` column — live for the entire build. On a rebuild of a corpus
  # that has never been archived, "every changed session" is every session in the
  # database that has a transcript, and materializing them together is what drove the
  # production worker's cgroup from a 1.5–2.5 GiB baseline to its 10 GiB cap in about
  # ninety seconds, roughly four times an hour. Loading one row per iteration puts a
  # ceiling of a single transcript on the job's peak, whatever the corpus does.
  #
  # `uncached` matters as much as the one-at-a-time loop. Rails runs a job inside the
  # executor's query cache, so without it every row loaded here would be retained by
  # the cache until `perform` returned — which reintroduces exactly the retention this
  # method exists to remove. CatalogRefreshJob reaches for `uncached` in the same place
  # for the same reason.
  def each_changed_session(changed_ids)
    changed_ids.each do |id|
      session = with_db_retry { Session.uncached { Session.find_by(id: id) } }
      next if session.nil? # deleted between the change scan and here

      yield session
    end
  end

  def update_zip(zip_path, changed_ids, all_sessions_metadata)
    Zip::File.open(zip_path) do |zip|
      each_changed_session(changed_ids) do |session|
        add_session_to_zip(zip, session)
        all_sessions_metadata[session.id.to_s] = session.updated_at.iso8601(6)
      end
    end
  end

  def build_full_zip(zip_path, changed_ids, previous_sessions, all_sessions_metadata, removed_session_ids)
    # We need to rebuild including unchanged sessions from the old archive
    # plus the changed sessions
    Zip::OutputStream.open(zip_path) do |_|
      # Just create the file
    end

    # First, copy unchanged sessions from the old archive if it exists
    if File.exist?(archive_path)
      unchanged_ids = previous_sessions.keys - removed_session_ids.to_a - changed_ids.map(&:to_s)

      Zip::File.open(zip_path) do |new_zip|
        Zip::File.open(archive_path) do |old_zip|
          old_zip.each do |entry|
            # Copy entries for unchanged sessions
            session_id = extract_session_id_from_path(entry.name)
            next unless session_id && unchanged_ids.include?(session_id)

            # Chunked rather than `os.write(entry.get_input_stream.read)`, which
            # inflated a whole archived transcript into one String per entry.
            new_zip.get_output_stream(entry.name) do |os|
              entry.get_input_stream { |is| Zip::IOExtras.copy_stream(os, is) }
            end
          end
        end

        # Add changed sessions
        each_changed_session(changed_ids) do |session|
          add_session_to_zip(new_zip, session)
          all_sessions_metadata[session.id.to_s] = session.updated_at.iso8601(6)
        end
      end
    else
      # First time building — only add changed sessions
      Zip::File.open(zip_path) do |zip|
        each_changed_session(changed_ids) do |session|
          add_session_to_zip(zip, session)
          all_sessions_metadata[session.id.to_s] = session.updated_at.iso8601(6)
        end
      end
    end
  end

  def add_session_to_zip(zip, session)
    session_data = {
      id: session.id,
      title: session.title,
      slug: session.slug,
      status: session.status,
      prompt: session.prompt,
      git_root: session.git_root,
      branch: session.branch,
      created_at: session.created_at&.iso8601,
      updated_at: session.updated_at&.iso8601,
      archived_at: session.archived_at&.iso8601,
      goal: session.goal,
      mcp_servers: session.mcp_servers,
      transcript: session.transcript
    }

    entry_name = "sessions/#{session.id}.json"

    # Remove existing entry if present (for updates)
    zip.remove(entry_name) if zip.find_entry(entry_name)

    # `generate`, not `pretty_generate`. A transcript is machine-read, and pretty-printing
    # one builds a second, larger copy of a payload that can run to hundreds of megabytes
    # purely to indent it. The small, human-read documents — manifest.json and the
    # metadata sidecar — stay pretty.
    zip.get_output_stream(entry_name) do |os|
      os.write(JSON.generate(session_data))
    end

    add_subagent_transcripts_to_zip(zip, session)
  end

  # Batched small and uncached for the same reason as each_changed_session: these rows
  # carry transcripts too, and `find_each`'s default batch of 1000 would hold a thousand
  # of them at once.
  def add_subagent_transcripts_to_zip(zip, session)
    with_db_retry do
      SubagentTranscript.uncached do
        session.subagent_transcripts.find_each(batch_size: BATCH_SIZE) do |subagent|
          subagent_data = {
            agent_id: subagent.agent_id,
            session_id: subagent.session_id,
            transcript: subagent.transcript,
            status: subagent.status,
            description: subagent.description,
            subagent_type: subagent.subagent_type,
            tool_use_id: subagent.tool_use_id,
            duration_ms: subagent.duration_ms,
            total_tokens: subagent.total_tokens,
            created_at: subagent.created_at&.iso8601,
            updated_at: subagent.updated_at&.iso8601
          }

          subagent_entry = "sessions/#{session.id}/subagent_transcripts/#{subagent.agent_id}.json"
          zip.remove(subagent_entry) if zip.find_entry(subagent_entry)

          zip.get_output_stream(subagent_entry) do |os|
            os.write(JSON.generate(subagent_data))
          end
        end
      end
    end
  end

  def write_manifest(zip_path, all_sessions_metadata)
    manifest = {
      session_count: all_sessions_metadata.size,
      generated_at: Time.current.iso8601,
      session_ids: all_sessions_metadata.keys.sort
    }

    Zip::File.open(zip_path) do |zip|
      zip.remove("manifest.json") if zip.find_entry("manifest.json")
      zip.get_output_stream("manifest.json") do |os|
        os.write(JSON.pretty_generate(manifest))
      end
    end
  end

  def write_metadata(all_sessions_metadata)
    metadata = {
      "generated_at" => Time.current.iso8601,
      "session_count" => all_sessions_metadata.size,
      "file_size_bytes" => File.exist?(archive_path) ? File.size(archive_path) : 0,
      "sessions" => all_sessions_metadata
    }

    File.write(metadata_path, JSON.pretty_generate(metadata))
  end

  def extract_session_id_from_path(path)
    # Match paths like "sessions/123.json" or "sessions/123/subagent_transcripts/..."
    match = path.match(%r{\Asessions/([^/]+)(?:\.json|/)})
    match&.[](1)
  end
end
