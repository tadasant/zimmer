# frozen_string_literal: true

# Captures MCP OAuth tokens the agent runtime refreshed mid-session back into
# Zimmer's canonical store (McpOauthCredential) — the missing write-back that let
# rotating-refresh-token servers (e.g. Notion) go stale.
#
# == Why this exists ==
#
# Zimmer stores each MCP server's OAuth tokens in McpOauthCredential and, at every
# spawn, writes them into the agent CLI's own credential store via a
# RuntimeMcpCredentialWriter. But Claude Code and Pi each ship their own MCP OAuth
# client: when an access token expires mid-session they refresh it and write the
# NEW pair back — Claude Code to ~/.claude/.credentials.json, Pi through the MCP
# SDK's OAuth provider, whose saveTokens lands in the OS credential store.
# Providers that rotate refresh tokens (OAuth 2.1 reuse-detection: every refresh
# mints a new refresh token and revokes the prior one) then leave Zimmer's DB
# holding a refresh token that has already been rotated away.
#
# Neither runtime can be told to stop refreshing — pi-mcp-adapter's `oauth: false`
# disables OAuth for the server outright rather than pinning the staged token, and
# Claude Code exposes nothing at all — so "Zimmer is the sole authority" is not a
# configuration that exists. Adopting back IS the design, and the ordering two
# writers would otherwise lack is supplied by #adoptable? below: only a strictly
# later access-token expiry is adopted, so the chain advances one way and a
# re-stamp of an older pair can never win.
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
# newer token pair, adopts it into the DB.
#
# For Claude Code that store is the session's own CLAUDE_CONFIG_DIR, so a
# reconciler is built per session by McpOauthCredentialInjector rather than once
# by the cron sweep. Subscription tokens need none of this: a Claude session is
# handed an access token and no refresh token, so it cannot rotate that chain at
# all (issue #618).
#
# == Matching ==
#
# Each runtime names its own entries, so the caller passes `runtime_key`: Claude
# Code and Codex key by the same "server_name|hash" credential key Zimmer
# persists (ClaudeMcpCredentialWriter#credential_key_for delegates to
# McpOauthCredential.compute_credential_key), and Pi keys by the bare
# `.mcp.json` server name. Codex is written-not-trusted (see
# CodexMcpCredentialWriter), so its store never holds a newer token and
# reconciling against it is a harmless no-op; Claude Code and Pi both refresh
# mid-session and both need adopting back.
#
# == How the store gets read ==
#
# A store that can be listed (one readable file) is read once and serves every
# credential from that snapshot. A store that can only be probed by key — Pi's,
# whose OS credential store is addressed by `sha256(server_name)` with no
# listing — is asked per key, memoized so a repeated key costs one read. Which
# one a reader is comes from RuntimeMcpCredentialWriter#enumerable_store?.
#
# Reading lazily also means a reconciler nobody asks anything of touches no
# store: constructing one is free, which is what lets the injector and the cron
# build one unconditionally.
class McpOauthRuntimeReconciler
  # @param reader [RuntimeMcpCredentialWriter] a runtime credential writer whose
  #   #read_runtime_credentials exposes what the runtime currently has on disk
  def initialize(reader)
    @reader = reader
    @enumerable = !reader.respond_to?(:enumerable_store?) || reader.enumerable_store?
    @snapshots = {}
    @probed = Set.new
    @listed = false
  end

  # Adopts a newer runtime-written token pair for `credential` into the DB.
  #
  # @param credential [McpOauthCredential] the DB record to reconcile
  # @param runtime_key [String] the key the runtime stored this server's entry
  #   under (defaults to the credential's own key, which equals Claude Code's)
  # @return [Boolean] true if the DB row was updated from the runtime store
  def reconcile!(credential, runtime_key: credential.credential_key)
    snapshot = snapshot_for(runtime_key)
    return false unless adoptable?(snapshot, credential)

    adopted = false
    credential.with_lock do
      # Re-check under the row lock: another session or the cron may have advanced
      # the DB past this snapshot since we read the file.
      next unless adoptable?(snapshot, credential)

      credential.update!(
        access_token: snapshot.access_token,
        refresh_token: snapshot.refresh_token,
        expires_at: snapshot.expires_at,
        # The runtime captured a refresh token from this server, which settles the
        # question the issuance-time flag was answering. Recording it keeps a later
        # invalidate_refresh_token! from resurrecting a claim this token disproved.
        refresh_token_unsupported: snapshot.refresh_token.blank? && credential.refresh_token_unsupported?
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
  rescue StandardError => e
    # Reconciliation is best-effort. A lock-contention or update failure
    # (ActiveRecord::Deadlocked, LockWaitTimeout, a dropped connection) is
    # exactly what concurrent sessions plus the cron can produce on a hot row,
    # and it must never propagate: in the spawn gate it would fail the session,
    # and in RefreshMcpOauthTokensJob it would be logged at .error and page the
    # alert channel for a self-resolving condition. Leave the DB copy in place —
    # the next spawn or cron run reconciles cleanly.
    Rails.logger.warn(
      "[McpOauthRuntimeReconciler] Skipped reconciliation for " \
      "#{credential.server_name} (#{credential.credential_key}): #{e.class}: #{e.message}"
    )
    false
  end

  private

  # The runtime's entry for `runtime_key`, reading the store on first need.
  def snapshot_for(runtime_key)
    if @enumerable
      unless @listed
        @listed = true
        @snapshots = read_store(nil)
      end
    elsif @probed.add?(runtime_key)
      @snapshots.merge!(read_store([ runtime_key ]))
    end

    @snapshots[runtime_key]
  end

  # A missing/corrupt runtime store must never block a spawn or a refresh — treat
  # it as "nothing to adopt" and let the existing DB tokens flow through. The
  # probe is still recorded as done, so a store that raises every time is asked
  # once per key rather than once per credential.
  def read_store(credential_keys)
    result = @reader.read_runtime_credentials(credential_keys)
    result.is_a?(Hash) ? result : {}
  rescue StandardError => e
    Rails.logger.warn "[McpOauthRuntimeReconciler] Failed to read runtime credentials: #{e.message}"
    {}
  end

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
  #
  # A DB row with NO expiry is not comparable, so it is not adopted over. A nil
  # expires_at means the provider issued no `expires_in`, which makes the access
  # token non-expiring — and a non-expiring token is one no runtime ever refreshes,
  # because the SDK only refreshes what it can see has lapsed. So the runtime's copy
  # cannot legitimately be ahead, and treating "the runtime recorded an expiry and we
  # did not" as newer would let a stale on-disk pair overwrite a freshly authorized
  # one: re-authorize, spawn, and the revoked pre-reauth token comes straight back.
  #
  # A snapshot that names a DIFFERENT server URL is not this credential's, however
  # its key matched. Pi's store is keyed by the bare `.mcp.json` server name, and
  # `server_name` is not unique across McpOauthCredential rows — a server whose URL
  # or headers changed leaves the old row behind — so two rows can probe one keyring
  # account. The adapter draws the same line from its own side (`getAuthForUrl`
  # returns nothing once the URL has moved).
  def adoptable?(snapshot, credential)
    return false if snapshot.nil?
    return false if snapshot.access_token.blank? || snapshot.refresh_token.blank?
    return false if snapshot.access_token == credential.access_token &&
      snapshot.refresh_token == credential.refresh_token
    return false if snapshot.server_url.present? && snapshot.server_url != credential.server_url
    return false if snapshot.expires_at.nil? || credential.expires_at.nil?

    snapshot.expires_at > credential.expires_at
  end
end
