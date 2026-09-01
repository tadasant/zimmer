# frozen_string_literal: true

# PiHome — the single source of truth for resolving the Pi coding agent's
# config directory and the paths Zimmer reads or writes underneath it.
#
# Pi keeps its host-global state under a config directory that defaults to
# `~/.pi/agent` and is overridden by `PI_CODING_AGENT_DIR`:
#
#   - auth.json     — provider credentials (`/login`, or an API key)
#   - models.json   — custom provider / model declarations
#   - settings.json — installed extensions
#   - sessions/     — session JSONL transcripts, when no --session-dir is given
#
# Zimmer deliberately does NOT read transcripts from `sessions/`. Pi accepts an
# explicit `--session-dir`, so PiRuntimeAdapter points every session at a
# per-clone directory instead (PiTranscriptSource.session_directory). That is the
# one substantive divergence from CodexHome, and it is what lets Pi avoid the
# whole class of bug CodexTranscriptSource#fallback_transcript exists to work
# around: two concurrent Codex sessions share one rollout tree and can latch onto
# each other's files, while two concurrent Pi sessions write into their own
# clones and cannot collide at all.
#
# What remains host-global for Pi is credentials and extension registration, so
# those are what this module resolves.
module PiHome
  # Pi's own default when PI_CODING_AGENT_DIR is unset.
  DEFAULT_RELATIVE_PATH = File.join(".pi", "agent")

  module_function

  # Absolute path to Pi's config directory, honoring the PI_CODING_AGENT_DIR
  # override and falling back to ~/.pi/agent (Pi's own default).
  def path
    ENV["PI_CODING_AGENT_DIR"].presence || File.join(Dir.home, DEFAULT_RELATIVE_PATH)
  end

  # Pi's auth.json (provider credentials) location.
  def auth_json_path
    File.join(path, "auth.json")
  end

  # Pi's models.json (custom provider declarations) location.
  def models_json_path
    File.join(path, "models.json")
  end

  # Pi's settings.json (installed extensions) location.
  def settings_json_path
    File.join(path, "settings.json")
  end
end
