# frozen_string_literal: true

# SessionHomeDirectory — the private HOME an isolated session runs with.
#
# Only sessions running under a uid of their own (SessionUid) get one. They cannot
# share the app's /home/rails: it holds the app's credentials, and anything a session
# wrote there (npm and pip caches, `gh` state, Claude's MCP logs) every other session
# could read. A session left out of the flag keeps HOME=/home/rails, as before.
#
# Durable and keyed on the session id, like SessionScratchDirectory: a sibling of the
# clones base on the `zimmer_data` volume, so it survives a deploy and the session's
# caches with it. DurableSessionStorage removes it with the session's other
# directories; Session#reclaim_session_directories when a row is deleted.
#
# Override the location with AGENT_SESSION_HOME_DIR.
module SessionHomeDirectory
  SUBDIR = "session-homes"

  module_function

  # @return [String]
  def base
    configured = ENV["AGENT_SESSION_HOME_DIR"].presence
    return File.expand_path(configured) if configured

    File.join(File.dirname(ClonesDirectory.base), SUBDIR)
  end

  # @return [String]
  def path_for(session_id)
    raise ArgumentError, "session_id is required" if session_id.blank?

    File.join(base, session_id.to_s)
  end

  def cleanup_for(session_id)
    return if session_id.blank?

    path = path_for(session_id)
    FileUtils.rm_rf(path) if Dir.exist?(path)
  rescue => e
    Rails.logger.warn("[SessionHomeDirectory] Failed to clean up home for session #{session_id}: #{e.message}")
  end
end
