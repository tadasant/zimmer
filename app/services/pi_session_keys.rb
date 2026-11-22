# frozen_string_literal: true

require "digest"

# Short-lived, spend-capped OpenRouter keys for Pi sessions.
#
# == Why
#
# Production invariant: agents never hold a secrets-store secret. Without this, a
# Pi process gets the account's long-lived `OPENROUTER_API_KEY` from the store
# (PiRuntimeAdapter#apply_provider_key). With it on, the backend holds a
# management key (`OPENROUTER_MANAGEMENT_KEY`, read from the store and never
# from ENV) and gives each Pi spawn a key of its own instead: capped in dollars,
# expiring on its own, and deleted when the session comes to rest.
#
# == Lifecycle
#
#   spawn       #mint_for_spawn! — revoke the session's earlier keys (a job,
#               off the spawn path), create a key, record its hash.
#   at rest     Session leaves `running` → PiProviderKeyRevokeJob deletes every
#               key the session minted before that moment, recording the spend
#               OpenRouter reports for it. An elicitation block is skipped: the
#               process is still alive and still needs its key.
#   sweep       PiProviderKeySweepJob — expired keys, keys whose session is at
#               rest or gone, and keys at OpenRouter under this deployment's name
#               prefix that have no row at all (a mint whose row write failed).
#
# == Expiry policy: one key per spawn, generous expiry, tight spend cap
#
# Each Pi spawn is one turn, and every spawn mints a fresh key. The expiry is
# deliberately long (TTL_HOURS, default 24h) so a long turn never loses its
# credential mid-way; what bounds a leaked key is the spend cap (LIMIT_USD) and
# the revoke when the turn ends, not the clock. The expiry is the backstop for
# the case where Zimmer itself is down and cannot revoke. The trade-off: a key
# copied out of a running turn is good for up to LIMIT_USD until the turn ends,
# and a turn that spends more than LIMIT_USD stops at OpenRouter's limit.
#
# == Enablement
#
# On only when BOTH hold: MODE_VARIABLE is `on` or `on_with_fallback`, and the
# management key resolves from the Parameter Store. Either missing → exactly the
# long-lived behaviour that predates this class.
#
# A mint that fails while on:
#   `on`                → the spawn fails, naming why. The long-lived key is
#                         never used, so the invariant holds.
#   `on_with_fallback`  → the spawn gets the long-lived key, and the fallback is
#                         reported (an error report, a warning on the session's
#                         timeline) every time it happens.
module PiSessionKeys
  MODE_VARIABLE = "PI_OPENROUTER_SESSION_KEYS"
  LIMIT_VARIABLE = "PI_OPENROUTER_SESSION_KEY_LIMIT_USD"
  TTL_VARIABLE = "PI_OPENROUTER_SESSION_KEY_TTL_HOURS"
  MANAGEMENT_KEY_VARIABLE = "OPENROUTER_MANAGEMENT_KEY"

  MODES = %w[off on on_with_fallback].freeze

  DEFAULT_LIMIT_USD = 20
  DEFAULT_TTL_HOURS = 24
  # OpenRouter accepts a limit below 1,000,000.
  MAX_LIMIT_USD = 999_999
  # A week: past that the expiry stops being a backstop.
  MAX_TTL_HOURS = 168

  # How old a key must be before the sweep may delete it as "at rest" or
  # "orphaned". Covers the window between a mint and the spawn it was for (and
  # between the OpenRouter create and the row write), so a sweep can never take
  # a key from a process that is about to start.
  SWEEP_GRACE = 10.minutes

  class MintError < StandardError; end

  module_function

  # @return [String] one of MODES. An unrecognised value is "off", logged.
  def mode(env: ENV)
    raw = env[MODE_VARIABLE].to_s.strip.downcase
    return "off" if raw.empty?
    return raw if MODES.include?(raw)

    Rails.logger.warn("[PiSessionKeys] #{MODE_VARIABLE} is set to an unrecognised value; treating it as off")
    "off"
  end

  def limit_usd(env: ENV)
    value = Float(env[LIMIT_VARIABLE].presence || DEFAULT_LIMIT_USD, exception: false)
    value = DEFAULT_LIMIT_USD if value.nil? || value <= 0
    [ value, MAX_LIMIT_USD ].min
  end

  def ttl(env: ENV)
    hours = Float(env[TTL_VARIABLE].presence || DEFAULT_TTL_HOURS, exception: false)
    hours = DEFAULT_TTL_HOURS if hours.nil? || hours <= 0
    [ [ hours, 1 ].max, MAX_TTL_HOURS ].min.hours
  end

  # The management key, from the Parameter Store link only.
  #
  # Never from encrypted credentials or ENV: a value in the worker's ENV is
  # inherited by every agent process the worker spawns, which would hand agents
  # the one credential that can mint any number of keys. CliSpawnEnv scrubs the
  # name regardless.
  #
  # @return [String, nil] nil when it is not in the store or the store cannot be read
  def management_key(chain: SecretProviders.chain)
    provider = chain.provider_for(MANAGEMENT_KEY_VARIABLE)
    return nil unless provider.is_a?(SecretProviders::ParameterStoreProvider)

    provider.get(MANAGEMENT_KEY_VARIABLE).presence
  rescue ParameterStore::AuthError, ParameterStore::StoreError => e
    Rails.logger.warn("[PiSessionKeys] could not read #{MANAGEMENT_KEY_VARIABLE} from the store: #{e.class}")
    nil
  end

  # @return [OpenrouterKeyClient, nil]
  def client(chain: SecretProviders.chain)
    key = management_key(chain: chain)
    key && OpenrouterKeyClient.new(management_key: key)
  end

  # Every key this deployment mints is named under this prefix, which is what
  # lets the orphan sweep delete only its own keys on an account other
  # deployments (or people) also mint on. The tag is derived from this
  # deployment's secret_key_base, so it is stable across deploys, different per
  # deployment, and says nothing about the secret.
  def name_prefix
    tag = Digest::SHA256.hexdigest("pi-session-keys:#{Rails.application.secret_key_base}")[0, 10]
    "zimmer-pi-#{tag}-"
  end

  # Mint a key for one Pi spawn and record it.
  #
  # @param session_id [Integer, nil]
  # @param client [OpenrouterKeyClient]
  # @return [String] the plaintext key, for the spawn environment only
  # @raise [MintError] when OpenRouter refuses or the row cannot be written
  def mint_for_spawn!(session_id:, client:, now: Time.current)
    # The session's earlier keys belong to processes that have exited (one Pi
    # process per session at a time). Revoking them is a job, not two HTTP
    # calls on the spawn path; the cutoff keeps it off the key minted below.
    enqueue_revoke(session_id, cutoff: now, reason: "superseded") if session_id

    expires_at = (now + ttl).change(usec: 0)
    limit = limit_usd
    name = "#{name_prefix}s#{session_id || 'none'}-#{now.utc.strftime('%Y%m%dT%H%M%SZ')}"

    minted = begin
      client.create(name: name, limit_usd: limit, expires_at: expires_at)
    rescue OpenrouterKeyClient::Error => e
      raise MintError, e.message
    end

    begin
      PiProviderKey.create!(session_id: session_id, key_hash: minted.key_hash, name: name,
                            limit_usd: limit, expires_at: expires_at)
    rescue StandardError => e
      # A key with no row would only be found by the orphan sweep. Delete it now.
      begin
        client.delete(minted.key_hash)
      rescue OpenrouterKeyClient::Error
        nil
      end
      raise MintError, "could not record the minted key: #{e.class}"
    end

    minted.key
  end

  # Delete one key at OpenRouter and mark its row revoked, recording the spend
  # OpenRouter reports for it. A key OpenRouter no longer has counts as revoked.
  #
  # @return [Boolean] true when the row is now revoked
  def revoke!(record, reason:, client:, now: Time.current)
    return true unless record.active?

    usage = begin
      client.get(record.key_hash)["usage"]
    rescue OpenrouterKeyClient::Error
      nil
    end

    begin
      client.delete(record.key_hash)
    rescue OpenrouterKeyClient::Error => e
      raise unless e.not_found?
    end

    # Conditional on the row still being active: the sweep and a revoke job can
    # both reach one key, and the second (whose GET and DELETE both 404) must not
    # overwrite the spend and reason the first recorded.
    PiProviderKey.active.where(id: record.id)
                 .update_all(revoked_at: now, revoke_reason: reason, last_error: nil, updated_at: now,
                             usage_usd: usage.is_a?(Numeric) ? usage : nil)
    record.reload
    true
  rescue OpenrouterKeyClient::Error => e
    record.update_columns(last_error: e.message.truncate(500), updated_at: now)
    Rails.logger.warn("[PiSessionKeys] could not revoke key #{record.id}: #{e.message}")
    false
  end

  # Revoke every active key the session minted before `cutoff`.
  # @return [Integer] how many were revoked
  def revoke_for_session!(session_id, cutoff:, reason:, client:)
    PiProviderKey.active.where(session_id: session_id).where(created_at: ..cutoff)
                 .count { |record| revoke!(record, reason: reason, client: client) }
  end

  def enqueue_revoke(session_id, cutoff:, reason:)
    PiProviderKeyRevokeJob.perform_later(session_id, cutoff.iso8601(6), reason)
  rescue StandardError => e
    # The sweep converges what this misses; a lost enqueue costs latency only.
    Rails.logger.warn("[PiSessionKeys] could not enqueue a revoke for session #{session_id}: #{e.class}")
  end

  # Whether the session still has a live Pi process that needs its key: running,
  # or parked on an approval round-trip with the process waiting on it.
  def session_live?(session)
    return false if session.nil?

    session.running? || (session.needs_input? && session.blocked_on_elicitation?)
  end
end
