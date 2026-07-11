# frozen_string_literal: true

# Single source of truth for a session's durable on-disk scratch directory.
#
# Why this exists
# ---------------
# Long-running agent sessions frequently stash cross-step state on disk (a
# multi-phase pipeline writes intermediate artifacts between phases, etc.).
# Agents naturally reach for `/tmp`, but in production `/tmp` lives on the
# container's ephemeral overlay layer and is wiped on every container
# recreation — including a routine Kamal deploy. A session that is mid-run when
# a deploy lands loses all of its `/tmp` artifacts and has to reconstruct them
# from scratch (see the Zimmer-side fix for the Discovery pipeline scratch wipe).
#
# This module hands each session a directory that lives INSIDE the durable
# `zimmer_data` named volume (mounted at /home/rails/.zimmer in both the app and
# worker containers — see infra/terraform/cloud-init.yaml.tftpl), so its
# contents survive container restarts and deploys exactly like the git clones
# do. The path is exported to the agent as AO_SESSION_SCRATCH_DIR.
#
# Durability + stability contract
# -------------------------------
#   * Durable: the base resolves under the same mount that backs ClonesDirectory,
#     so scratch survives deploys/restarts with no relocation.
#   * Keyed on the session id (NOT the clone path): a session's clone path hash
#     changes when its clone is recreated (e.g. after a relocate), but the
#     session id is stable, so the scratch dir is the same directory across the
#     entire life of the session — including resume after a clone recreation.
#   * Sibling of the clones base (not under it): the orphan-clone filesystem
#     sweep scans ClonesDirectory.base and reaps anything there that doesn't map
#     to a live session. Placing scratch alongside (not inside) that base keeps
#     it out of the sweep's path entirely.
#
# Override the location with the AGENT_SCRATCH_DIR environment variable. If you
# point it OUTSIDE the mounted named volume you MUST add a corresponding durable
# volume mount in the deploy config, otherwise scratch will be wiped on the next
# deploy.
module SessionScratchDirectory
  SCRATCH_SUBDIR = "session-scratch"

  module_function

  # The scratch base directory (parent of every per-session scratch dir).
  #
  # Resolved at call time (never memoized) so tests that stub HOME and ops that
  # set AGENT_SCRATCH_DIR are both honored without a process restart.
  #
  # @return [String] absolute path to the scratch base directory
  def base
    configured = ENV["AGENT_SCRATCH_DIR"].presence
    return File.expand_path(configured) if configured

    # Sibling of the clones base, under the same durable mount. dirname of the
    # clones base is the durable `~/.zimmer` root in production.
    File.join(File.dirname(ClonesDirectory.base), SCRATCH_SUBDIR)
  end

  # Absolute path to a specific session's scratch directory (does not create it).
  #
  # @param session_id [Integer, String] the Zimmer session id
  # @return [String] absolute path to the session's scratch directory
  # @raise [ArgumentError] if session_id is blank
  def path_for(session_id)
    raise ArgumentError, "session_id is required" if session_id.blank?

    File.join(base, session_id.to_s)
  end

  # Ensure a session's scratch directory exists, creating it (and the base) if
  # needed, and return its absolute path.
  #
  # @param session_id [Integer, String] the Zimmer session id
  # @return [String] absolute path to the session's scratch directory
  def ensure_for(session_id)
    path = path_for(session_id)
    FileUtils.mkdir_p(path)
    path
  end

  # Remove a session's scratch directory if it exists. Scratch is reconstructable
  # state, so this deletes outright rather than preserving — it is called from the
  # clone GC when a session's clone is reaped.
  #
  # Defensive: never raises. A failure to reclaim scratch must not break clone
  # cleanup, so errors are swallowed (best-effort, logged by the caller's job
  # context if a logger is available).
  #
  # @param session_id [Integer, String] the Zimmer session id
  # @return [void]
  def cleanup_for(session_id)
    return if session_id.blank?

    path = path_for(session_id)
    FileUtils.rm_rf(path) if Dir.exist?(path)
  rescue => e
    Rails.logger.warn("[SessionScratchDirectory] Failed to clean up scratch for session #{session_id}: #{e.message}")
  end
end
