# frozen_string_literal: true

# NullRuntimeArtifactBridge — the bridge for a runtime whose AIR adapter already
# activates the session's hooks and plugins.
#
# Claude Code and Codex both take this. `air prepare claude` writes the hook table
# into `.claude/settings.json` and materializes plugin content itself; Codex has no
# hook surface for AIR to translate into, so there is nothing for Zimmer to write
# after the fact either way.
#
# A null object rather than a nil slot, for the reason RuntimeBundleSlotContractTest
# exists: AirPrepareService dereferences this slot on every prepare of every
# runtime, so a nil here would be a NoMethodError on every Claude and Codex session
# rather than a quietly skipped step.
class NullRuntimeArtifactBridge < RuntimeArtifactBridge
  def write!
    nil
  end
end
