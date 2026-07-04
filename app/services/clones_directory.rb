# frozen_string_literal: true

# Single source of truth for the base directory under which every agent session's
# git clone lives.
#
# Durability contract
# -------------------
# In production this MUST resolve to durable storage that survives container
# restarts AND Kamal deploys. That durability is provided by the
# `agent-orchestrator_agent-clones` Docker named volume, mounted at
# /home/rails/.agent-orchestrator on both the web and worker containers (see
# config/deploy.production.yml). The default below (`~/.agent-orchestrator/clones`)
# resolves inside that mount, so clones persist across deploys with no physical
# relocation required.
#
# Override the location with the AGENT_CLONES_DIR environment variable. If you
# point it OUTSIDE the mounted named volume you MUST add a corresponding durable
# volume mount in the deploy config, otherwise clones will be wiped on the next
# deploy. Use the `clones:relocate` rake task to move existing clones (and update
# session metadata) when the base directory changes.
#
# Why a single resolver
# ---------------------
# Every consumer that creates, locates, or reaps a clone resolves the base path
# through this module. This guarantees writers (GitCloneService, ForkSessionService)
# and the garbage collector (StaleCloneCleanupJob, OrphanCloneFilesystemCleanupJob)
# can never disagree about where clones live — a divergence that would otherwise
# let the orphan sweep delete live clones because it was scanning the wrong base.
module ClonesDirectory
  DEFAULT_HOME_SUBDIR = ".agent-orchestrator"
  CLONES_SUBDIR = "clones"

  module_function

  # The clones base directory.
  #
  # Resolved at call time (never memoized) so that tests which stub HOME and ops
  # that set AGENT_CLONES_DIR are both honored without a process restart.
  #
  # @return [String] absolute path to the clones base directory
  def base
    configured = ENV["AGENT_CLONES_DIR"].presence
    return File.expand_path(configured) if configured

    File.join(File.expand_path("~"), DEFAULT_HOME_SUBDIR, CLONES_SUBDIR)
  end
end
