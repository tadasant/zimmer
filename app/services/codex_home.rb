# frozen_string_literal: true

# CodexHome — the single source of truth for resolving the Codex CLI's home
# directory (CODEX_HOME).
#
# The Codex CLI persists everything for a session under CODEX_HOME:
#
#   - auth.json            — login credentials (the auth provider reconciles this)
#   - sessions/YYYY/MM/DD/  — rollout JSONL transcripts (the transcript source reads these)
#   - state_*.sqlite        — the thread store
#
# `codex exec resume <thread-id>` resolves a thread by its ROLLOUT FILE, so the
# directory the spawned `codex` WRITES rollouts to must be the same directory AO
# READS transcripts from on a later turn. If those diverge — or if CODEX_HOME
# lives on an ephemeral filesystem that is wiped between turns — resume fails
# with "no rollout found for thread id".
#
# CODEX_HOME overrides the default ~/.codex, mirroring the Codex CLI itself.
# Every AO component that touches Codex state (the auth provider, the transcript
# source, the MCP credential writer, and the spawn environment) MUST resolve the
# path through this module so they never disagree about where Codex state lives.
#
# Some callers snapshot the result into a constant at boot (the auth provider's
# CODEX_HOME / AUTH_JSON_PATH, the credential writer's CODEX_CREDENTIALS_PATH)
# while others call these methods per request (the transcript source, the spawn
# env). That is safe because CODEX_HOME is a static process ENV (set once in the
# image and never mutated at runtime), so the boot snapshot and the call-time
# read always agree. Tests swap the boot constants via remove_const/const_set.
module CodexHome
  module_function

  # Absolute path to CODEX_HOME, honoring the CODEX_HOME env override and
  # falling back to ~/.codex (the Codex CLI's own default).
  def path
    ENV["CODEX_HOME"].presence || File.join(Dir.home, ".codex")
  end

  # Where the Codex CLI writes rollout transcripts (date-partitioned tree).
  def sessions_path
    File.join(path, "sessions")
  end

  # The Codex CLI's auth.json (login credentials) location.
  def auth_json_path
    File.join(path, "auth.json")
  end
end
