# frozen_string_literal: true

# DMs the operator when a runtime account falls into needs_reauth.
#
# A needs_reauth account is not broken in a way Zimmer can fix: its refresh token
# is permanently invalid, so the pool simply stops drawing on it and keeps going
# with a smaller pool. Nothing surfaces that anywhere a human looks — the failure
# is logged at .warn precisely so it does NOT page #eng-alerts (a channel alert
# for a condition only a human can clear is noise), and the account sits dead on
# /quotas until someone happens to open the page. That gap is what this closes:
# one DM, to the person who can re-authenticate, naming the account.
#
# Fired from ClaudeAccount's status-transition callback rather than from the call
# sites that condemn an account, so no path can bypass it. See
# ClaudeAccount#notify_status_transition for why the recovery paths that write
# the status with `update_columns` are correctly excluded.
class AccountReauthNotifier
  SOURCE = "ClaudeAccount"

  RUNTIME_LABELS = {
    "claude_code" => "Claude",
    "codex" => "Codex"
  }.freeze

  class << self
    # Keyed per account, not per title: two dead accounts are two problems and
    # must produce two DMs.
    def dedup_key(account)
      "claude_account_needs_reauth:#{account.id}"
    end

    # @param account [ClaudeAccount]
    # @return [Boolean] true if a DM was sent
    def notify(account)
      # Re-checked here because this runs from a background job: the account may
      # have been recovered (or deleted, or re-authenticated) between the
      # transition that enqueued it and this run, and a DM about an account that
      # is working again is worse than no DM.
      return false unless account.needs_reauth?

      AlertService.dm_operator(
        "#{runtime_label(account)} account needs re-authentication",
        details: details_for(account),
        source: SOURCE,
        dedup_key: dedup_key(account)
      )
    end

    # Drop the suppression when an account leaves needs_reauth, so a genuine
    # second failure inside the window still reaches a human.
    def clear(account)
      AlertService.clear_dm_suppression(dedup_key(account))
    end

    private

    def runtime_label(account)
      RUNTIME_LABELS.fetch(account.runtime.to_s, account.runtime.to_s)
    end

    def details_for(account)
      quotas_url = "#{AppUrl.base_url.to_s.chomp('/')}/quotas"

      <<~DETAILS.strip
        *#{account.email}* (#{runtime_label(account)}) can no longer refresh its token, so the account pool has stopped drawing on it. It stays out of rotation until a human re-authenticates — Zimmer cannot recover this on its own.

        Open <#{quotas_url}|/quotas> and re-authenticate this account.
      DETAILS
    end
  end
end
