# frozen_string_literal: true

# The read-modify-write discipline for a Claude Code session's `.credentials.json`.
#
# That file used to be host-global, with two writers inside Zimmer and a third
# outside it — the account pool's `claudeAiOauth` block, ClaudeMcpCredentialWriter's
# `mcpOAuth` map, and the CLI rewriting both. Nobody owned the whole file, and
# on 2026-08-22 that cost the pool three hours (issue #618).
#
# It is per-session now: each session gets its own CLAUDE_CONFIG_DIR, Zimmer
# writes only the `mcpOAuth` map into it, and no subscription token is ever on
# disk. Two writers are left — ClaudeMcpCredentialWriter and the CLI — and they
# still overlap, because a session's spawn and its follow-ups both inject while
# the CLI refreshes MCP tokens mid-session. So the rule is unchanged: no writer
# may write the whole file from its own snapshot, because a plain `File.write` of
# one block's blob discards what the other writer put beside it. One lock file,
# one atomic write.
#
# Every entry point takes the credentials path rather than reading a constant,
# which is what lets one implementation serve every session's own file.
module ClaudeCredentialStore
  # A dedicated lock file, so the lock is never the file being replaced by rename.
  # It is derived from the credentials path's directory: relocating the
  # credentials path relocates the lock with it.
  LOCK_FILENAME = ".zimmer-credential-store.lock"

  class << self
    # Serializes a read-modify-write of one session's credential store against
    # every other writer of that same file. Without it, two overlapping writers
    # each merge into the snapshot they read and the last one wins, silently
    # dropping the other's entry.
    #
    # @param credentials_path [String] the credentials file being modified
    def with_lock(credentials_path)
      dir = File.dirname(credentials_path)
      FileUtils.mkdir_p(dir)

      File.open(File.join(dir, LOCK_FILENAME), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    # Parses a JSON store, or returns {} when it is absent or corrupt. A store we
    # cannot read means "nothing recorded", never an error — callers merge into the
    # result, and refusing to write at all would strand the credentials Zimmer is
    # trying to install.
    #
    # @return [Hash]
    def read(path)
      return {} unless File.exist?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError => e
      Rails.logger.warn "[ClaudeCredentialStore] Failed to parse #{path}: #{e.message}"
      {}
    end

    # Writes JSON through a temp file + rename so a concurrent reader never
    # observes a half-written store. The temp path is process-unique because the
    # same host-global path is written by every session on the worker.
    def write_atomically(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      temp_path = "#{path}.#{Process.pid}.tmp"
      File.write(temp_path, JSON.pretty_generate(data))
      File.chmod(0o600, temp_path)
      File.rename(temp_path, path)
    end
  end
end
