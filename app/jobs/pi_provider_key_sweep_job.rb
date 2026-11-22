# frozen_string_literal: true

# Converges the short-lived OpenRouter keys minted for Pi sessions: deletes every
# key that should no longer exist. See PiSessionKeys.
#
# Two passes, both idempotent:
#
#   1. Rows. An active key is deleted when it has expired, when its session is
#      gone, or when its session is no longer live (PiSessionKeys.session_live?)
#      and the key is older than PiSessionKeys::SWEEP_GRACE. This retries every
#      revoke the at-rest hook missed or failed.
#   2. OpenRouter. A key under this deployment's name prefix with no row at all
#      is a mint whose row write never happened; it is deleted once it is older
#      than the grace. Keys under any other name are never touched.
#
# Runs whether or not the feature is on, so turning it off still cleans up what
# it minted, and does nothing at all without the management key in the store.
class PiProviderKeySweepJob < ApplicationJob
  include SingletonSweep

  queue_as :default

  BATCH = 200
  MAX_PAGES = 20

  def perform(client: nil, now: Time.current)
    return unless PiProviderKey.active.exists? || PiSessionKeys.mode != "off"

    client ||= PiSessionKeys.client
    return if client.nil?

    sweep_rows(client, now)
    sweep_orphans(client, now)
  end

  private

  def sweep_rows(client, now)
    PiProviderKey.active.order(:created_at).limit(BATCH).each do |record|
      reason = revoke_reason_for(record, now)
      PiSessionKeys.revoke!(record, reason: reason, client: client, now: now) if reason
    end
  end

  def revoke_reason_for(record, now)
    return "expired" if record.expires_at <= now
    return nil if record.created_at > now - PiSessionKeys::SWEEP_GRACE

    session = record.session_id && Session.find_by(id: record.session_id)
    return "session_gone" if session.nil?
    return nil if PiSessionKeys.session_live?(session)

    "session_at_rest"
  end

  def sweep_orphans(client, now)
    prefix = PiSessionKeys.name_prefix

    MAX_PAGES.times do |page|
      keys = client.list(offset: page * OpenrouterKeyClient::PAGE_SIZE)
      keys.each { |key| delete_orphan(client, key, prefix, now) }
      break if keys.size < OpenrouterKeyClient::PAGE_SIZE
    end
  rescue OpenrouterKeyClient::Error => e
    Rails.logger.warn("[PiProviderKeySweep] could not list OpenRouter keys: #{e.message}")
  end

  def delete_orphan(client, key, prefix, now)
    hash = key["hash"].to_s
    return unless key["name"].to_s.start_with?(prefix) && hash.present?
    return if PiProviderKey.exists?(key_hash: hash)

    created_at = Time.zone.parse(key["created_at"].to_s) rescue nil
    return if created_at.nil? || created_at > now - PiSessionKeys::SWEEP_GRACE

    client.delete(hash)
    Rails.logger.info("[PiProviderKeySweep] deleted an orphaned key #{key['name']}")
  rescue OpenrouterKeyClient::Error => e
    Rails.logger.warn("[PiProviderKeySweep] could not delete orphaned key #{key['name']}: #{e.message}") unless e.not_found?
  end
end
