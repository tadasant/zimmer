# frozen_string_literal: true

# Reads a session clone's `.env` file (KEY=VALUE) into a hash.
#
# Two places need the same answer to "what did the operator put in this clone's
# .env?": CliSpawnEnv, which builds the agent CLI process's environment at spawn
# time, and RuntimeConfigPostProcessor, which writes the elicitation variables
# into each stdio MCP server's own `env` table at prepare time. Both must agree on
# those, or an operator pointing a session at a different Zimmer would move the
# agent process and not its servers — so the parser lives here rather than in
# either caller. (Only those two names are bridged into a server's env table; the
# rest of a `.env` reaches the agent process, and on Claude the servers that
# inherit it.)
#
# Format supported (deliberately the same, minimal dialect Zimmer has always
# parsed):
#
#   - comments (lines starting with #) and blank lines are skipped
#   - quoted values: KEY="value" / KEY='value' (matching quotes stripped)
#   - empty values: KEY=
#   - invalid lines are skipped rather than raising
#
# Not supported: multi-line values, variable expansion ($HOME), escape sequences
# inside quotes.
class EnvFile
  FILENAME = ".env"

  # Guard against memory exhaustion from a huge or malicious .env.
  MAX_BYTES = 1.megabyte

  # Variable names: must start with a letter or underscore, then letters,
  # digits, underscores (ASCII only).
  LINE_PATTERN = /\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/

  class << self
    # @param working_dir [String] directory to look for `.env` in
    # @param file_system [FileSystemAdapter] injectable file system
    # @param logger [#warn] where oversize/parse failures are reported
    # @return [Hash{String=>String}] parsed variables; empty when absent or unreadable
    def load(working_dir, file_system:, logger: Rails.logger)
      return {} if working_dir.blank?

      path = File.join(working_dir, FILENAME)
      return {} unless file_system.exists?(path)

      content = file_system.read(path)
      if content.bytesize > MAX_BYTES
        logger.warn "Skipping .env file: exceeds maximum size of #{MAX_BYTES} bytes (actual: #{content.bytesize} bytes)"
        return {}
      end

      parse(content)
    rescue => e
      logger.warn "Failed to load .env file: #{e.message}"
      {} # Never fail the caller over a bad .env
    end

    # @param content [String] raw .env contents
    # @return [Hash{String=>String}]
    def parse(content)
      content.to_s.each_line.with_object({}) do |line, vars|
        line = line.strip
        next if line.empty? || line.start_with?("#")
        next unless (match = LINE_PATTERN.match(line))

        vars[match[1]] = unquote(match[2].strip)
      end
    end

    private

    def unquote(value)
      return value unless value.length >= 2
      return value[1..-2] if value.start_with?('"') && value.end_with?('"')
      return value[1..-2] if value.start_with?("'") && value.end_with?("'")

      value
    end
  end
end
