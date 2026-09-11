# frozen_string_literal: true

# Can a Claude Code session authenticate right now, and if not, what does a
# human have to do about it?
#
# The question used to be about a file. On 2026-08-22 the Claude CLI blanked its
# own `claudeAiOauth.accessToken` and `refreshToken` in the host-global
# `~/.claude/.credentials.json` — empty strings, every other field intact —
# after Zimmer pushed a spent refresh token at it, and every session on the
# worker was logged out for three hours while the condition had no health
# surface at all. See https://github.com/tadasant/zimmer/issues/618.
#
# There is no such file now. Each session is spawned with its own
# CLAUDE_CONFIG_DIR and the current account's access token in
# CLAUDE_CODE_OAUTH_TOKEN, so "can a session authenticate" is answered entirely
# by the DB row that token comes out of — and a row cannot be blanked by a
# process Zimmer does not control. What is left is the health surface, reported
# in the same three states the file had, about the row instead.
#
# There is deliberately no repair. A corrupt file could be rewritten from the
# DB; an unusable DB row is the bottom of the stack, and the only thing that
# fixes it is a human re-authenticating from /inference. Saying so is more
# useful than a self-heal that cannot work.
class ClaudeCredentialHealth
  # The states the pool's current credential can be in, worst last.
  #
  #   :ok      - the current account holds a complete claudeAiOauth token pair.
  #   :absent  - no account is current yet. Normal on a fresh deployment before
  #              the first login, and not a fault: the next session spawn selects
  #              one from the pool. Never escalated.
  #   :corrupt - an account IS current but its stored pair is unusable. Every
  #              session spawned from it is logged out.
  #
  # `:mcp_only` is gone with the file it described: a credentials file holding an
  # `mcpOAuth` map and no subscription tokens was a state only a shared file
  # could be in.
  STATES = %i[ok absent corrupt].freeze

  Status = Data.define(:state, :detail, :owner_email, :checked_at) do
    def ok? = state == :ok
    def corrupt? = state == :corrupt
  end

  class << self
    # Classify the credential a Claude Code session would be spawned with.
    # Pure read — never writes, so it is safe on a GET and safe to call from the
    # health dashboard.
    #
    # @return [Status]
    def status
      account = ClaudeAccount.current_account(ClaudeAuthProvider::RUNTIME)
      now = Time.current

      if account.nil?
        return Status.new(state: :absent,
          detail: "No Claude account is current. The next session spawn selects one from the pool.",
          owner_email: nil, checked_at: now)
      end

      if ClaudeAccount.complete_claude_oauth?(account.oauth_config&.dig("credentials_json"))
        Status.new(state: :ok,
          detail: "Sessions authenticate from the database as #{account.email}; no credentials file is in play.",
          owner_email: account.email, checked_at: now)
      else
        Status.new(state: :corrupt,
          detail: "#{account.email} is the current account but its stored tokens are incomplete — every session " \
                  "spawned from it is logged out. Re-authenticate #{account.email} from /inference.",
          owner_email: account.email, checked_at: now)
      end
    end
  end
end
