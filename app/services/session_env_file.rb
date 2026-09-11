# frozen_string_literal: true

# Writes a session clone's `.env` — the Zimmer-managed half of it.
#
# The counterpart to EnvFile, which reads one. Two things live in this file and
# they have different owners:
#
#   - **Zimmer's block**, rewritten from scratch on every call: the secrets from
#     `SecretsLoader.all` that SessionSecretScope says this session may hold.
#     Read that class for the rule and for the ways back out of a narrowing.
#   - **Everything else**, carried over verbatim. An operator (or the agent
#     itself) can set a variable in a clone's `.env` — pointing a server at a
#     different Zimmer with `ELICITATION_REQUEST_URL`, raising
#     `PARALLEL_WORKERS`, giving a non-Zimmer project its own `SENTRY_DSN` — and
#     several call sites document that as a supported override. This file is
#     rewritten on every runtime-config prepare, so regenerating it whole would
#     erase those on the session's next turn. Foreign lines are copied through as
#     RAW TEXT, never re-quoted: the dialect EnvFile parses does not unescape, so
#     parsing a value and re-emitting it through #format_entry would double every
#     backslash in it.
class SessionEnvFile
  # Marks the block this class owns. Ownership is by NAME, not by position: every
  # line setting a name in the bundle is regenerated wherever it sits, and every
  # other line is preserved wherever it sits — see #preserved_lines.
  MANAGED_HEADER = "# --- Zimmer-managed secrets (regenerated on every prepare; edits to these keys are lost) ---"

  # How many names a log line lists before it summarises the rest as a count.
  SUMMARY_NAME_LIMIT = 20

  Result = Struct.new(:key_names, :available_count, keyword_init: true) do
    # What goes in a log line: names, never values, and never so many of them
    # that the line stops being readable — `ZIMMER_SESSION_ENV_SCOPE=all` would
    # otherwise put the whole bundle's names in every session's log.
    def summary
      return "no secrets" if key_names.empty?

      listed = key_names.first(SUMMARY_NAME_LIMIT).join(", ")
      extra = key_names.size - SUMMARY_NAME_LIMIT
      extra.positive? ? "#{listed} (+#{extra} more)" : listed
    end
  end

  class << self
    # Regenerate the managed block of `working_directory/.env`.
    #
    # Raises on a genuine write failure rather than swallowing it, because the
    # two callers want different things said about it: AgentSessionJob puts a
    # warning in the session's own log feed (where the user and the agent can
    # both see it), and AirPrepareService puts one in the Rails log. Neither lets
    # it fail the session — a clone without its secrets is worse off than one
    # with them, and much better off than one that never starts.
    #
    # @param session [Session]
    # @param working_directory [String]
    # @param file_system [FileSystemAdapter]
    # @return [Result, nil] nil when there was nothing to write
    def write!(session:, working_directory:, file_system:)
      return nil if session.nil? || working_directory.blank?

      secrets = SecretsLoader.all
      return nil if secrets.empty?

      allowed = SessionSecretScope.allowed_keys(session: session, available_keys: secrets.keys)
      scoped = secrets.slice(*allowed)

      path = File.join(working_directory, EnvFile::FILENAME)
      # `perm:` sets the mode on a file this call creates, so a new `.env` is never
      # briefly world-readable under the umask; the chmod covers one that existed.
      file_system.write(path, render(scoped, preserved_lines(path, file_system, secrets.keys)), perm: 0o600)
      file_system.chmod(0o600, path)

      Result.new(key_names: scoped.keys.sort, available_count: secrets.size)
    end

    private

    # Every line of the existing file that Zimmer does not own: not the header,
    # and not a line setting a name Zimmer manages. Filtering by NAME rather than
    # by position is what makes the narrowing stick — a stale managed key left
    # behind by an older, unscoped write has to be dropped wherever in the file
    # it sits, including below the header, and a foreign line appended after the
    # block has to survive.
    def preserved_lines(path, file_system, managed_names)
      return [] unless file_system.exists?(path)

      content = file_system.read(path).to_s
      return [] if content.bytesize > EnvFile::MAX_BYTES

      managed = managed_names.to_set
      content.each_line.map(&:chomp).reject do |line|
        stripped = line.strip
        next true if stripped == MANAGED_HEADER

        (match = EnvFile::LINE_PATTERN.match(stripped)) && managed.include?(match[1])
      end
    rescue StandardError
      # An unreadable .env is replaced rather than merged. Losing an override is
      # recoverable; refusing to write the session's credentials is not.
      []
    end

    def render(scoped, preserved)
      lines = preserved.dup
      lines.pop while lines.last&.strip&.empty?
      lines << "" if lines.any?
      lines << MANAGED_HEADER
      lines.concat(scoped.map { |key, value| format_entry(key, value) })
      "#{lines.join("\n")}\n"
    end

    # KEY="value", with the escaping Zimmer has always used: double quotes so a
    # value carrying `=` or a newline survives the line-oriented parser, inner
    # quotes and backslashes escaped, newlines flattened to a literal `\n`.
    # EnvFile does not unescape any of it, so this is what the consumer sees —
    # which is what Google service-account keys already expect.
    def format_entry(key, value)
      escaped = value.to_s.gsub("\\", "\\\\\\\\").gsub('"', '\\"').gsub("\n", "\\n")
      "#{key}=\"#{escaped}\""
    end
  end
end
