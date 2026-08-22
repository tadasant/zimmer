# frozen_string_literal: true

# Is the shared ~/.claude/.credentials.json usable, and if not, can Zimmer fix it
# without a human?
#
# On 2026-08-22 the Claude CLI blanked its own `claudeAiOauth.accessToken` and
# `refreshToken` — empty strings, every other field intact — after Zimmer pushed
# a spent refresh token at it. Zimmer noticed: `sync_tokens_from_filesystem!`
# logged "credentials are corrupted" and declined to adopt the wreckage into the
# DB, correctly. Then it did nothing else, 126 times an hour, for three hours.
# The condition had no health surface, no repair, and no escalation; a human
# found it by reading transcripts.
#
# This class is the missing three. It answers the state (#status), repairs the
# one state that is repairable (#self_heal!), and gives
# HealthMonitorService and RefreshRuntimeAuthTokensJob something to escalate on.
#
# See https://github.com/tadasant/zimmer/issues/618, holes 5 and 6.
class ClaudeCredentialHealth
  # The states the shared credentials file can be in, worst last.
  #
  #   :ok        - a complete claudeAiOauth token pair is present.
  #   :absent    - no file at all. Normal on a fresh worker before the first
  #                credential write, and not a fault: the next session spawn
  #                writes one. Never escalated.
  #   :mcp_only  - a file with no claudeAiOauth block, only the other writer's
  #                mcpOAuth map. Also not a fault — it is what a worker looks
  #                like when MCP servers have been authorized and no
  #                subscription credential has been written yet.
  #   :corrupt   - a claudeAiOauth block IS present but its accessToken or
  #                refreshToken is missing or empty. This is the incident shape.
  #                Nothing reads this file successfully; every session on the
  #                worker is logged out until it is repaired.
  STATES = %i[ok absent mcp_only corrupt].freeze

  Status = Data.define(:state, :detail, :owner_email, :checked_at) do
    def ok? = state == :ok
    def corrupt? = state == :corrupt
  end

  class << self
    # Classify the shared credentials file. Pure read — never writes, so it is
    # safe on a GET and safe to call from the health dashboard.
    #
    # @return [Status]
    def status
      path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
      owner = ClaudeAccount.credentials_owner_email

      unless File.exist?(path)
        return Status.new(state: :absent, detail: "No credentials file on the worker yet.", owner_email: owner, checked_at: Time.current)
      end

      data = ClaudeCredentialStore.read(path)
      oauth = data["claudeAiOauth"]

      if oauth.blank?
        return Status.new(state: :mcp_only,
          detail: "The credentials file holds no subscription tokens (#{data.fetch("mcpOAuth", {}).size} MCP OAuth entries).",
          owner_email: owner, checked_at: Time.current)
      end

      if ClaudeAccount.complete_claude_oauth?(data)
        Status.new(state: :ok, detail: "Subscription tokens present for #{owner || "an unrecorded account"}.",
          owner_email: owner, checked_at: Time.current)
      else
        Status.new(state: :corrupt, detail: corrupt_detail(oauth, owner), owner_email: owner, checked_at: Time.current)
      end
    end

    # Rewrite a corrupt credentials file from the DB copy of the account that
    # owns it, when that copy is complete.
    #
    # The DB is the better source here by construction: a corrupt file has no
    # tokens to lose, so this write cannot destroy anything, and the DB copy is
    # the only remaining candidate for a working credential. `force: true` for
    # the same reason — the backwards-write guard exists to protect a LIVE
    # on-disk credential, and there isn't one.
    #
    # Idempotent: a healthy file, an absent file, an unowned file, or an owner
    # whose DB copy is itself incomplete all return :skipped with a reason, so
    # this is safe to call on every sweep.
    #
    # @return [Array(Symbol, String)] [:healed | :skipped | :failed, detail]
    def self_heal!
      current = status
      return [ :skipped, "credentials are #{current.state}, nothing to repair" ] unless current.corrupt?

      owner = current.owner_email
      return [ :skipped, "no account owns the credentials file, so there is no DB copy to restore from" ] if owner.blank?
      return [ :skipped, "the credentials file is marked unowned" ] if owner == ClaudeAccount::UNOWNED_CREDENTIALS_MARKER

      account = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).find_by(email: owner)
      return [ :skipped, "no #{ClaudeAuthProvider::RUNTIME} account for #{owner}" ] if account.nil?

      unless ClaudeAccount.complete_claude_oauth?(account.oauth_config&.dig("credentials_json"))
        return [ :skipped, "#{owner}'s stored credentials are incomplete too — only a human re-authentication can fix this" ]
      end

      if account.write_credentials_to_filesystem!(force: true)
        Rails.logger.warn "[ClaudeCredentialHealth] Repaired the corrupt shared credentials file from #{owner}'s stored credentials"
        [ :healed, "rewrote the credentials file from #{owner}'s stored credentials" ]
      else
        [ :failed, "the write of #{owner}'s stored credentials was refused" ]
      end
    rescue StandardError => e
      Rails.logger.error "[ClaudeCredentialHealth] Self-heal failed: #{e.message}"
      [ :failed, e.message ]
    end

    private

    def corrupt_detail(oauth, owner)
      missing = %w[accessToken refreshToken].reject { |field| oauth[field].present? }
      blanked = missing.select { |field| oauth.key?(field) }
      shape =
        if blanked.any?
          "#{blanked.to_sentence} blanked to empty strings"
        else
          "#{missing.to_sentence} missing"
        end
      "The credentials file on the worker has #{shape} — every session on it is logged out" \
        "#{owner.present? ? " (owner: #{owner})" : ""}."
    end
  end
end
