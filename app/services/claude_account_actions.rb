# frozen_string_literal: true

# The account verbs /inference and `/api/v1/inference` share: add an account to a
# pool, probe one account's quota, switch the current account, delete one, start
# its CLI login, and converge a stale status column against the reading on file.
#
# One implementation, so the page and the iOS app cannot disagree about whether
# an account may be switched to, which account a delete activates, or what a
# probe records. The controllers keep only their response shape.
class ClaudeAccountActions
  # A verb the account's state does not allow, in a sentence the human can act
  # on. The web flashes it; the API answers 422 with it.
  class Refused < StandardError; end

  # One quota probe and what a card renders from it: the reading now on file
  # (fresh when the probe succeeded, the last one otherwise) and the probe's
  # error when it failed.
  Probe = Data.define(:snapshot, :error)

  # The outcome of a switch or a delete: the sentence the web flashes, and the
  # account now current for the runtime (nil when none remains).
  Outcome = Data.define(:message, :current_account)

  class << self
    # Create the DB row for an account. Codex may carry an API key and is usable
    # at once; an OAuth account is created empty and authenticated afterwards.
    #
    # Email uniqueness is per runtime: the same email may hold a separate account
    # on another runtime (one codex + one claude_code account).
    def add!(runtime:, email:, priority: 0, api_key: nil)
      email = email.to_s.strip
      raise Refused, "Email is required to add an account." if email.blank?

      if ClaudeAccount.for_runtime(runtime).exists?(email: email)
        raise Refused, "An account for #{email} already exists in the #{RuntimeRegistry.label_for(runtime)} pool."
      end

      account = ClaudeAccount.new(email: email, runtime: runtime, priority: priority.to_i)
      account.oauth_config = { "api_key" => api_key.to_s.strip } if runtime == CodexAuthProvider::RUNTIME && api_key.present?
      # The status column defaults to :active (enum 0), but a freshly-added account
      # with no credentials yet isn't servable and shouldn't wear an "Active" badge
      # in the pool — it's excluded from the `available` serve pool anyway (that
      # scope requires a non-empty oauth_config). Seed it as :needs_reauth so the UI
      # honestly reads "needs authentication" until capture! flips it to :active.
      account.status = :needs_reauth unless account.has_valid_config?
      account.save!
      account
    rescue ActiveRecord::RecordInvalid => e
      raise Refused, "Could not add account: #{e.record.errors.full_messages.to_sentence}"
    end

    # Probe one account's quota and record the reading. `trigger` names why the
    # snapshot was taken (ClaudeAccountQuotaSnapshot).
    def probe(account, trigger:)
      result = probe_token(account)
      snapshot = result&.success? ? QuotaSnapshotService.save_snapshot(account, result, trigger: trigger) : account.latest_snapshot
      Probe.new(snapshot: snapshot, error: result&.success? ? nil : result&.error_message)
    end

    # Make `account` the runtime's current account, or raise Refused with why it
    # cannot be. `triggered_by` names the actor on the rotation event.
    def switch!(account, triggered_by: nil)
      refusal = switch_refusal(account)
      raise Refused, refusal if refusal

      runtime = account.runtime
      current = ClaudeAccount.current_account(runtime)

      # Route through the provider's activate! so manual switches take exactly the
      # same activation path as automatic rotations: mark current in the DB,
      # snapshot (Claude), write ~/.codex/auth.json (Codex). Doing it by hand here
      # would leave the two entry points free to drift.
      RuntimeAuthProvider.for(runtime).activate!(account)

      # Re-activating the account that is already current is a repair, not a
      # rotation: for a runtime that keeps a credential file (Codex), it rewrites
      # that file from the DB copy. Recording it as a rotation from an account to
      # itself would put a meaningless row in the history operators read to
      # understand rotations. Claude Code offers no such control — there is no file
      # to repair (issue #618) — but a direct POST still lands here, and answering
      # it as a rotation-to-self would be the same meaningless row.
      reactivation = current&.id == account.id

      unless reactivation
        AccountRotationEvent.create(
          rotated_from: current,
          rotated_to: account,
          reason: "manual_switch",
          source: "manual",
          triggered_by: triggered_by
        )
      end

      message = reactivation ? "Re-activated #{account.email}." : "Switched to #{account.email}"
      Outcome.new(message: message, current_account: account)
    end

    # Remove an account from its runtime's pool. When the deleted account is the
    # current one, activate the next available account in that runtime (or leave
    # the runtime with no current account if none remain). The next spawn reads
    # the new current account out of the DB (Codex also rewrites auth.json).
    #
    # The account row goes; its history does not. Quota snapshots, login attempts,
    # and rotation events are nullified rather than destroyed, and each carries the
    # account's email — see ClaudeAccount's associations.
    def delete!(account, triggered_by: nil)
      runtime = account.runtime
      email = account.email
      was_current = account.is_current?

      account.destroy!

      return Outcome.new(message: "Deleted #{email}.", current_account: ClaudeAccount.current_account(runtime)) unless was_current

      next_account = next_activatable(runtime)
      if next_account
        RuntimeAuthProvider.for(runtime).activate!(next_account)
        # The source account is already gone, so it can only be named by the
        # email preserved on the event — which is what tells the rotation table
        # this move came from a deleted account rather than from nowhere.
        AccountRotationEvent.create(
          rotated_from: nil,
          rotated_from_email: email,
          rotated_to: next_account,
          reason: "deleted_current_account",
          source: "manual",
          triggered_by: triggered_by
        )
        Outcome.new(message: "Deleted #{email}. Activated #{next_account.email} as the current account.",
          current_account: next_account)
      else
        Outcome.new(message: "Deleted #{email}. No other configured account remains — this runtime now has no active account.",
          current_account: nil)
      end
    end

    # Begin a UI-driven login for an OAuth account: supersede any in-flight
    # attempt, create a fresh RuntimeLoginAttempt, and enqueue RuntimeLoginJob
    # (which holds the login CLI open in the worker).
    def start_login!(account)
      raise Refused, "API-key accounts don't use the login flow." if account.codex? && account.codex_api_key_account?

      # Only one live attempt per account — supersede any existing one so we never
      # leave two login CLIs racing. The supersede-then-create runs under a row lock
      # on the account so two near-simultaneous Authenticate clicks can't each cancel
      # the other's not-yet-created row and both end up live.
      attempt = account.with_lock do
        account.runtime_login_attempts.active.update_all(
          status: "canceled", pasted_code: nil, updated_at: Time.current
        )
        account.runtime_login_attempts.create!(runtime: account.runtime)
      end
      RuntimeLoginJob.perform_later(attempt.id)
      attempt
    end

    # The first available account in the runtime whose credentials validate, so a
    # safe-delete fallback never activates a bricked account. Codex API-key
    # accounts skip the refresh probe.
    def next_activatable(runtime)
      ClaudeAccount.available.for_runtime(runtime).find do |account|
        if account.codex? && account.codex_api_key_account?
          true
        else
          account.can_refresh_token? && account.refresh_token!
        end
      end
    end

    # Converge the status column of every quota-exceeded account in `runtime`
    # whose latest reading says its windows have cleared. Same predicate
    # QuotaResetCheckerJob restores on, logged the same way: a status flipping
    # without a line saying which reading did it is not something anyone can
    # reconstruct afterwards.
    #
    # A healing failure must never take the surface with it. /inference is where a
    # human goes to fix an auth problem, and a row that fails validation for some
    # reason of its own is not a reason to deny them the page.
    #
    # @param snapshots [Hash{Integer => ClaudeAccountQuotaSnapshot}] by account id
    # @param log_tag [String] which surface did it, for the log line
    def heal(runtime, snapshots, log_tag:)
      ClaudeAccount.quota_exceeded.for_runtime(runtime).each do |account|
        snapshot = snapshots[account.id]
        next unless snapshot
        next unless snapshot.windows_clear?

        account.update!(status: :active)
        Rails.logger.info "[#{log_tag}] Restored #{account.email} to active: both windows are clear " \
          "(5h #{snapshot.utilization_5h.inspect}/#{snapshot.status_5h.inspect}, " \
          "7d #{snapshot.utilization_7d.inspect}/#{snapshot.status_7d.inspect}, " \
          "reading taken #{snapshot.created_at&.iso8601})"
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn "[#{log_tag}] Could not restore #{account.email} to active: #{e.message}"
      end
    end

    private

    # Why `account` cannot be made current, or nil when it can. Codex API-key
    # accounts authenticate statically — nothing to refresh. OAuth accounts (both
    # runtimes) must hold a refresh token that validates against the vendor before
    # we hand potentially-revoked credentials to a session.
    def switch_refusal(account)
      unless account.has_valid_config?
        return "Cannot switch to #{account.email} — no credentials stored. Authenticate the account first."
      end

      return nil if account.codex? && account.codex_api_key_account?

      unless account.can_refresh_token?
        return "Cannot switch to #{account.email} — no refresh token. Re-authenticate the account."
      end

      # A stored access token Anthropic still honours is the direct answer to the
      # question this method is actually asking — can this account serve a session
      # — and unlike #refresh_token! it does not spend the single-use refresh
      # token to find out. Gating admission on a refresh ROUND TRIP is what let the
      # failure block its own repair: an account freshly authenticated through the
      # UI holds a working access token and an unused refresh token, and demanding
      # a refresh here burned the latter to learn nothing about the former.
      #
      # Sits AFTER the refresh-token existence check on purpose. A pair with no
      # refresh token is a dead end even while its access token works — in eight
      # hours nothing can mint another — so "it works right now" must not admit it.
      # See issue #618, hole 4.
      return nil if account.access_token_honored?

      unless account.refresh_token!
        # A rejection Zimmer could not attribute to a dead credential leaves the
        # account active on purpose (#530), so telling the human to re-authenticate
        # would be telling them to fix something that is probably not broken.
        if account.reload.needs_reauth?
          return "Cannot switch to #{account.email} — token validation failed. Re-authenticate the account."
        end

        return "Cannot switch to #{account.email} — its stored token was rejected as out of date. Try again shortly, or re-authenticate if it keeps failing."
      end

      nil
    end

    def probe_token(account)
      return nil unless account.can_refresh_token?

      if account.token_expired? || account.token_expiring_soon?
        account.refresh_token!
        account.reload
      end

      token = account.claude_access_token
      return nil unless token.present?

      result = QuotaCheckService.check_with_token(token)

      if !result.success? && result.credential_refused? && account.can_refresh_token?
        if account.refresh_token!
          account.reload
          token = account.claude_access_token
          result = QuotaCheckService.check_with_token(token) if token.present?
        end
      end

      # The verdict, after the one refresh this method allows — so the card the
      # caller is about to re-render reports what Anthropic just said about the
      # token now in the row rather than whether the row is non-empty (#239).
      account.record_credential_probe!(result, probed_token: token)

      result
    end
  end
end
