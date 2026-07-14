# frozen_string_literal: true

# Captures MCP OAuth tokens the agent runtime refreshed mid-session back into
# Zimmer's canonical store (McpOauthCredential) — the missing write-back that let
# rotating-refresh-token servers (e.g. Notion) go stale.
#
# == Why this exists ==
#
# Zimmer stores each MCP server's OAuth tokens in McpOauthCredential and, at every
# spawn, writes them into the agent CLI's own credential store via a
# RuntimeMcpCredentialWriter. But Claude Code has its own MCP OAuth client: when an
# access token expires mid-session it refreshes it and writes the NEW pair back to
# ~/.claude/.credentials.json. Providers that rotate refresh tokens (OAuth 2.1
# reuse-detection: every refresh mints a new refresh token and revokes the prior
# one) then leave Zimmer's DB holding a refresh token that has already been
# rotated away.
#
# ClaudeMcpCredentialWriter#merge_preserving_fresher! keeps that fresher on-disk
# entry ONLY while its paired access token is still valid. Across an idle gap
# longer than the access token's TTL (~1h for Notion) the on-disk access token
# lapses, so on the next spawn Zimmer's (stale) DB entry wins and clobbers the
# good on-disk refresh token. The next refresh — Claude Code's at connect time, or
# RefreshMcpOauthTokensJob's from cron — then presents the dead token and gets
# `invalid_grant: Invalid refresh token`, and the server drops offline until a
# human re-authorizes.
#
# This reconciler closes the loop: before Zimmer refreshes or injects a
# credential, it reads the runtime store and, if the runtime holds a strictly
# newer token pair, adopts it into the DB. ClaudeAccount#sync_tokens_from_filesystem!
# does exactly this for the runtime's OWN account tokens; MCP OAuth credentials had
# no equivalent.
#
# == Matching ==
#
# The runtime store is keyed by the same "server_name|hash" credential key Zimmer
# persists (ClaudeMcpCredentialWriter#credential_key_for delegates to
# McpOauthCredential.compute_credential_key), so a credential matches its on-disk
# entry directly by key. Only Claude Code refreshes MCP tokens mid-session; Codex
# is written-not-trusted (see CodexMcpCredentialWriter), so its store never holds
# a newer token and reconciling against it is a harmless no-op.
class McpOauthRuntimeReconciler
  # @param reader [RuntimeMcpCredentialWriter] a runtime credential writer whose
  #   #read_runtime_credentials exposes what the runtime currently has on disk
  def initialize(reader)
    @snapshots = reader.read_runtime_credentials
  rescue StandardError => e
    # A missing/corrupt runtime store must never block a spawn or a refresh — treat
    # it as "nothing to adopt" and let the existing DB tokens flow through.
    Rails.logger.warn "[McpOauthRuntimeReconciler] Failed to read runtime credentials: #{e.message}"
    @snapshots = {}
  end

  # Adopts a newer runtime-written token pair for `credential` into the DB.
  #
  # @param credential [McpOauthCredential] the DB record to reconcile
  # @param runtime_key [String] the key the runtime stored this server's entry
  #   under (defaults to the credential's own key, which equals Claude Code's)
  # @return [Boolean] true if the DB row was updated from the runtime store
  def reconcile!(credential, runtime_key: credential.credential_key)
    snapshot = @snapshots[runtime_key]
    return false unless adoptable?(snapshot, credential)

    adopted = false
    credential.with_lock do
      # Re-check under the row lock: another session or the cron may have advanced
      # the DB past this snapshot since we read the file.
      next unless adoptable?(snapshot, credential)

      credential.update!(
        access_token: snapshot.access_token,
        refresh_token: snapshot.refresh_token,
        expires_at: snapshot.expires_at
      )
      adopted = true
    end

    if adopted
      Rails.logger.info(
        "[McpOauthRuntimeReconciler] Adopted runtime-refreshed token for " \
        "#{credential.server_name} (#{credential.credential_key})"
      )
    end
    adopted
  rescue ActiveRecord::RecordNotFound
    # The credential was deleted between load and lock — nothing to adopt.
    false
  end

  private

  # True when the on-disk snapshot is a strictly newer token pair worth adopting.
  #
  # We adopt when the runtime's access token was minted with a LATER expiry than
  # the DB's — a later expiry means the runtime refreshed after Zimmer last wrote
  # the row, and for a rotating provider that same refresh rotated the refresh
  # token. Crucially we adopt even when the on-disk access token has since expired:
  # a rotated refresh token is the live head of the chain regardless of whether its
  # paired access token is still within TTL (this is the exact case
  # merge_preserving_fresher! drops). A snapshot missing either token, or not newer
  # than the DB, or byte-identical to it, is skipped so we never null out a token
  # or churn updated_at (which the cron's rotation throttle keys on).
  def adoptable?(snapshot, credential)
    return false if snapshot.nil?
    return false if snapshot.access_token.blank? || snapshot.refresh_token.blank?
    return false if snapshot.access_token == credential.access_token &&
      snapshot.refresh_token == credential.refresh_token
    return false if snapshot.expires_at.nil?
    return true if credential.expires_at.nil?

    snapshot.expires_at > credential.expires_at
  end
end
