# frozen_string_literal: true

# The credential environment for a `claude` process that belongs to no Zimmer
# session — the one-off `claude -p` inference behind session titles, status
# summaries, push-notification copy and category inference.
#
# Why this exists
# ---------------
# A Claude session gets its credentials from ClaudeSpawnEnv: its own
# CLAUDE_CONFIG_DIR and the current account's access token in
# CLAUDE_CODE_OAUTH_TOKEN. Print-mode inference had no such seam — it spawned
# `claude -p` with the worker's inherited environment, which meant the CLI read
# the host-global `~/.claude/.credentials.json`. That file stopped being written
# when the DB became the sole owner of the subscription chain (issue #618), so
# every one of those calls answered `Not logged in · Please run /login` and
# exited 1, which HeadlessInferenceService logged and discarded. The symptom was
# silent by construction: each caller falls back to a default (the provisional
# session title stands, the summary is skipped), so nothing failed loudly enough
# to be noticed.
#
# So these processes get the same treatment a session's does, from the same
# source of truth.
#
# One shared config dir, not one per call
# ---------------------------------------
# Keyed on DIRECTORY_KEY rather than on anything per-call, deliberately. These
# invocations are stateless — one prompt in, one answer out, `--resume` never
# enters it — so there is no conversation state to keep apart, and a directory
# per call would leave a new directory on the durable volume every time a
# session is titled. It sits under the same base as the per-session dirs, so it
# inherits their durability and the `projects/` symlink that keeps every
# transcript reader correct.
module ClaudeHeadlessCredentials
  # The config-directory key these processes share. Not a valid session id, so
  # it can never collide with ClaudeSessionConfigDirectory's per-session dirs.
  DIRECTORY_KEY = "headless"

  module_function

  # The env overlay for one print-mode `claude` invocation.
  #
  # Returns an EMPTY hash when the pool has nothing to offer, and that is the
  # right failure here rather than the raise ClaudeSpawnEnv does. A session that
  # cannot authenticate is a session that cannot work, so failing its spawn is
  # the honest outcome; a title that cannot be generated is a cosmetic
  # degradation the caller already handles. Spawning with no token produces the
  # same exit-1 the caller already treats as "no answer", and it says so in the
  # log.
  #
  # @return [Hash{String => String}]
  def env
    account = ClaudeAccount.current_account(ClaudeAuthProvider::RUNTIME)
    token = account&.claude_access_token

    if token.blank?
      Rails.logger.warn "[ClaudeHeadlessCredentials] No Claude account holds a usable access token — " \
        "print-mode inference will report 'Not logged in'. Authenticate one from /inference."
      return {}
    end

    {
      "CLAUDE_CONFIG_DIR" => ClaudeSessionConfigDirectory.ensure_for(DIRECTORY_KEY),
      "CLAUDE_CODE_OAUTH_TOKEN" => token
    }
  rescue StandardError => e
    # Never fatal. Inference is a best-effort sprinkle and its callers all have a
    # fallback; a DB blip here must degrade the completion, not raise into a job.
    Rails.logger.warn "[ClaudeHeadlessCredentials] Could not resolve credentials for print-mode inference: #{e.message}"
    {}
  end
end
