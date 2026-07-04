# frozen_string_literal: true

# Injects `--prefix /tmp` into an `npx` MCP server invocation so npx resolves
# the package against /tmp rather than walking up from the working directory
# into a surrounding workspace (which can pick up the wrong package or fail
# resolution entirely).
#
# Runtime-agnostic: operates on the `{ "command" => ..., "args" => [...] }`
# shape shared by Claude's `.mcp.json` entries and Codex's
# `.codex/config.toml` `[mcp_servers.*]` tables. A no-op for any entry whose
# command is not `npx`.
module NpxPrefixRewriter
  module_function

  # Insert `--prefix /tmp` into the entry's args, in place. The prefix must come
  # early in the args (right after `-y` when present) so npx treats it as its
  # own flag rather than a package argument.
  def rewrite!(entry)
    return unless entry.is_a?(Hash) && entry["command"] == "npx"

    args = entry["args"]
    return unless args.is_a?(Array)
    return if args.include?("--prefix") # Already has prefix

    y_index = args.index("-y")
    insert_index = y_index ? y_index + 1 : 0
    args.insert(insert_index, "--prefix", "/tmp")
  end
end
