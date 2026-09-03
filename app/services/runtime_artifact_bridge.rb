# frozen_string_literal: true

# RuntimeArtifactBridge — the seam for a runtime that needs Zimmer to hand it the
# session's AIR hooks and plugins in a form the runtime can actually read.
#
# Most runtimes need nothing here. `air prepare claude` writes Claude Code's
# `settings.json` hook table and materializes plugin content itself, and Codex has
# no hook surface to write to. Pi is the exception: `@pulsemcp/air-adapter-pi` is
# skills-only by design ("Hooks — Pi has no AIR-translatable hook lifecycle. Hook
# entries are ignored... Plugins — honored only as composition sugar"), so after
# `air prepare pi` runs there is nothing on disk that carries the session's hooks
# or its plugins' hooks. PiAirBridge writes that missing config.
#
# The bridge runs after `air prepare` and after the MCP post-processor, because
# what it writes has to agree with both: it reads the session's selections through
# the same catalog readers the UI renders from, and it deliberately leaves MCP
# alone (see PiAirBridge for why).
class RuntimeArtifactBridge
  attr_reader :session, :working_directory, :file_system

  # @param session [Session] the session being prepared
  # @param working_directory [String] the session's working directory (the clone)
  # @param file_system [FileSystemAdapter] injectable file system
  def initialize(session:, working_directory:, file_system:)
    @session = session
    @working_directory = working_directory
    @file_system = file_system
  end

  # Write whatever this runtime needs to activate the session's hooks and plugins.
  #
  # @return [void]
  def write!
    raise NotImplementedError, "#{self.class}#write! is not implemented"
  end
end
