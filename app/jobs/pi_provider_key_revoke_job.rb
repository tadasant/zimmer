# frozen_string_literal: true

# Deletes the short-lived OpenRouter keys a Pi session minted before `cutoff`.
# Enqueued when a session leaves `running` (its turn is over) and when a new
# spawn supersedes an earlier key. See PiSessionKeys.
#
# The cutoff is what keeps a late-running job off a key minted for the NEXT
# turn: a session that comes to rest and is resumed a second later has a new
# key created after the cutoff, and this job leaves it alone.
#
# A key this job fails to delete stays active with its error recorded, and
# PiProviderKeySweepJob retries it.
class PiProviderKeyRevokeJob < ApplicationJob
  queue_as :default

  def perform(session_id, cutoff, reason)
    return unless PiProviderKey.active.where(session_id: session_id).exists?

    client = PiSessionKeys.client
    if client.nil?
      Rails.logger.warn("[PiProviderKeyRevoke] session #{session_id}: #{PiSessionKeys::MANAGEMENT_KEY_VARIABLE} " \
                        "is not in the store, so its keys are left to expire")
      return
    end

    # Decided at enqueue time; checked again here. A session that went back to
    # `running` holds keys minted after the cutoff, which this would skip anyway,
    # but a live process is never worth a guess. The sweep converges the rest.
    return if reason == "session_at_rest" && PiSessionKeys.session_live?(Session.find_by(id: session_id))

    PiSessionKeys.revoke_for_session!(session_id, cutoff: Time.zone.parse(cutoff), reason: reason, client: client)
  end
end
