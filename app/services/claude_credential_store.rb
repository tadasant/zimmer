# frozen_string_literal: true

# The read-modify-write discipline for Claude Code's host-global credential file,
# `~/.claude/.credentials.json`.
#
# That one file has two writers inside Zimmer and a third outside it:
#
#   - ClaudeAccount#write_credentials_to_filesystem! owns the `claudeAiOauth`
#     subscription tokens (which account the CLI is logged in as).
#   - ClaudeMcpCredentialWriter owns the `mcpOAuth` map (per-server MCP OAuth
#     tokens) and the sibling needs-auth cache.
#   - the Claude Code CLI itself rewrites both blocks at runtime.
#
# Nobody owns the whole file, so no writer may write the whole file from its own
# snapshot: a plain `File.write` of one block's blob discards whatever another
# writer put in the other block. Both Zimmer writers therefore go through here —
# one lock file, one atomic write — so the two are actually coordinated rather
# than coincidentally ordered.
#
# Every entry point takes the credentials path rather than reading a constant, so
# each caller keeps its own (test-relocatable) path constant. In production they
# resolve to the same file, which is what makes the lock coordinate anything.
module ClaudeCredentialStore
  # A dedicated lock file, so the lock is never the file being replaced by rename.
  # It is derived from the credentials path's directory: relocating the
  # credentials path relocates the lock with it.
  LOCK_FILENAME = ".zimmer-credential-store.lock"

  class << self
    # Serializes a read-modify-write of the credential store against every other
    # writer on the host — other sessions' credential injections and Zimmer's own
    # account writes alike. Without it, two overlapping writers each merge into the
    # snapshot they read and the last one wins, silently dropping the other's block.
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
