# frozen_string_literal: true

require "zip"
require "fileutils"

# Periodic job that incrementally builds/updates a zip file containing all session transcripts.
#
# Runs every 10 minutes. On each run, it:
# 1. Loads metadata from the previous run to identify already-archived sessions
# 2. Queries all sessions with transcripts, finding new or changed ones
# 3. Updates only the changed entries in the zip file
# 4. Writes atomically via temp file + rename
#
# The resulting zip is served by Api::V1::TranscriptArchivesController.
#
class TranscriptArchiveJob < ApplicationJob
  include DatabaseRetry
  queue_as :default

  ARCHIVE_DIR = Rails.root.join("storage", "transcript_archives")
  ARCHIVE_PATH = ARCHIVE_DIR.join("latest.zip")
  METADATA_PATH = ARCHIVE_DIR.join("latest_metadata.json")
  BATCH_SIZE = 50

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
      subagent_session_ids.each do |sid|
        session_id = sid.to_s
        next if previous_sessions.key?(session_id) && !removed_session_ids.include?(session_id)

        # Already queued from main transcript check
        next if session_ids_to_archive.include?(sid)

        session = Session.find_by(id: sid)
        if session
          removed_session_ids.delete(session_id)
          session_ids_to_archive << sid
        end
      end
    end

    sessions_to_archive = with_db_retry do
      Session.where(id: session_ids_to_archive.to_a).to_a
    end

    if sessions_to_archive.empty? && removed_session_ids.empty? && File.exist?(archive_path)
      Rails.logger.info "[TranscriptArchiveJob] No changes detected, skipping rebuild"
      return
    end

    build_archive(sessions_to_archive, previous_sessions, removed_session_ids)
  end

  # Path accessors — instance methods so tests can stub them for isolation
  def archive_dir
    ARCHIVE_DIR
  end

  def archive_path
    ARCHIVE_PATH
  end

  def metadata_path
    METADATA_PATH
  end

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

  def build_archive(changed_sessions, previous_sessions, removed_session_ids)
    temp_path = archive_dir.join("latest_#{SecureRandom.hex(8)}.zip.tmp")
    all_sessions_metadata = previous_sessions.dup

    # Remove deleted sessions from tracking
    removed_session_ids.each { |id| all_sessions_metadata.delete(id) }

    begin
      if File.exist?(archive_path) && removed_session_ids.empty?
        # Copy existing archive and update incrementally
        FileUtils.cp(archive_path, temp_path)
        update_zip(temp_path, changed_sessions, all_sessions_metadata)
      else
        # Build from scratch (first run or sessions were removed)
        build_full_zip(temp_path, changed_sessions, previous_sessions, all_sessions_metadata, removed_session_ids)
      end

      # Write manifest
      write_manifest(temp_path, all_sessions_metadata)

      # Atomic rename
      FileUtils.mv(temp_path, archive_path)

      # Write metadata
      write_metadata(all_sessions_metadata)

      Rails.logger.info "[TranscriptArchiveJob] Archive updated: #{all_sessions_metadata.size} sessions, " \
                        "#{changed_sessions.size} changed, #{removed_session_ids.size} removed, " \
                        "#{File.size(archive_path)} bytes"
    ensure
      File.delete(temp_path) if File.exist?(temp_path)
    end
  end

  def update_zip(zip_path, changed_sessions, all_sessions_metadata)
    Zip::File.open(zip_path) do |zip|
      changed_sessions.each do |session|
        add_session_to_zip(zip, session)
        all_sessions_metadata[session.id.to_s] = session.updated_at.iso8601(6)
      end
    end
  end

  def build_full_zip(zip_path, changed_sessions, previous_sessions, all_sessions_metadata, removed_session_ids)
    # We need to rebuild including unchanged sessions from the old archive
    # plus the changed sessions
    Zip::OutputStream.open(zip_path) do |_|
      # Just create the file
    end

    # First, copy unchanged sessions from the old archive if it exists
    if File.exist?(archive_path)
      unchanged_ids = previous_sessions.keys - removed_session_ids.to_a - changed_sessions.map { |s| s.id.to_s }

      Zip::File.open(zip_path) do |new_zip|
        Zip::File.open(archive_path) do |old_zip|
          old_zip.each do |entry|
            # Copy entries for unchanged sessions
            session_id = extract_session_id_from_path(entry.name)
            next unless session_id && unchanged_ids.include?(session_id)

            new_zip.get_output_stream(entry.name) { |os| os.write(entry.get_input_stream.read) }
          end
        end

        # Add changed sessions
        changed_sessions.each do |session|
          add_session_to_zip(new_zip, session)
          all_sessions_metadata[session.id.to_s] = session.updated_at.iso8601(6)
        end
      end
    else
      # First time building — only add changed sessions
      Zip::File.open(zip_path) do |zip|
        changed_sessions.each do |session|
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

    zip.get_output_stream(entry_name) do |os|
      os.write(JSON.pretty_generate(session_data))
    end

    # Add subagent transcripts
    with_db_retry do
      session.subagent_transcripts.find_each do |subagent|
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
          os.write(JSON.pretty_generate(subagent_data))
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
