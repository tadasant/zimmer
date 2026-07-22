# Resumes a session that was blocked waiting for MCP OAuth authorization.
#
# When a session needs OAuth for one or more MCP servers it cannot start: it is
# parked in a blocked state and its required servers are recorded in
# metadata["oauth_required_servers"]. The user authorizes each server one at a
# time. This service is invoked after each authorization completes and decides
# whether the session can now continue.
#
# The session's original intent — its prompt — is already durably stored on the
# Session record, so resuming is a matter of re-queuing the initial run via
# AgentSessionJob.enqueue_new_session, which replays that prompt. This service
# owns the "should we resume yet, and resume exactly once" decision.
#
# A session is considered OAuth-blocked when it is either:
#   - failed with metadata["failure_reason"] == "oauth_required", or
#   - waiting with metadata["oauth_required_servers"] still present
#
# Behavior:
#   - All required servers authorized AND no active pending flows remain
#       -> atomically transition back to waiting, clear the OAuth metadata, and
#          enqueue the original run. Returns :resumed.
#   - Some servers still need authorization (or a pending flow is still active)
#       -> trim oauth_required_servers to those still outstanding so the UI
#          reflects progress, leaving the session blocked. Returns :partial.
#   - The session is not (or no longer) blocked -> Returns :not_blocked.
#
# Exactly-once resume is guaranteed by running the whole decision under a row
# lock (with_lock = SELECT ... FOR UPDATE + reload). Once the first caller
# resumes the session, the OAuth metadata is cleared as part of the same locked
# transaction, so a concurrent or retried callback re-reads the post-resume
# state, sees the session is no longer blocked, and does nothing.
class McpOauthResumeService
  # @param session [Session] the session to evaluate for resumption
  def initialize(session)
    @session = session
  end

  # @return [Symbol] :resumed, :partial, or :not_blocked
  def call
    @session.with_lock do
      return :not_blocked unless blocked?

      remaining = servers_still_needing_oauth

      if remaining.empty? && pending_flows.none?
        resume!
        :resumed
      else
        record_partial_progress(remaining)
        :partial
      end
    end
  end

  private

  attr_reader :session

  # True when the session is parked waiting for OAuth authorization. A session
  # that has already been resumed (waiting with no oauth_required_servers) is
  # not blocked, which is what makes the resume idempotent under the row lock.
  def blocked?
    return true if session.failed? && session.metadata&.dig("failure_reason") == "oauth_required"

    session.waiting? && required_servers.present?
  end

  def required_servers
    session.metadata&.dig("oauth_required_servers") || []
  end

  def servers_still_needing_oauth
    required_servers.reject { |server_info| authorized?(server_info) }
  end

  def authorized?(server_info)
    key = McpOauthServerAuthorization.credential_key_for(server_info)
    if key.blank?
      # We can't derive a credential key for this recorded server (no key
      # persisted, not in the catalog, and no usable server_url — e.g. the
      # post-spawn MCP-failure path recorded it after a catalog miss). We
      # cannot evaluate authorization, so the server stays outstanding and the
      # session remains blocked rather than resuming prematurely. Warn because
      # this is a dead-end that won't self-resolve and needs human attention.
      server_name = server_info["server_name"] || server_info[:server_name]
      Rails.logger.warn(
        "[McpOauthResumeService] Cannot resolve a credential key for required server " \
        "#{server_name.inspect} on session #{session.id}; it will remain blocked until " \
        "the entry can be matched to a credential."
      )
      return false
    end

    McpOauthCredential.for_credential_key(key).active.exists?
  end

  def pending_flows
    McpOauthPendingFlow.for_session(session).active
  end

  def resume!
    session.update!(
      status: "waiting",
      metadata: session.metadata.merge(
        "oauth_complete" => true,
        "failure_reason" => nil,
        "oauth_required_servers" => nil
      )
    )

    AgentSessionJob.enqueue_new_session(session.id)

    Rails.logger.info(
      "[McpOauthResumeService] All OAuth flows complete for session #{session.id}, " \
      "auto-resuming original intent"
    )
  end

  def record_partial_progress(remaining)
    # Nothing newly authorized since the list was last written — leave it alone.
    return if remaining.length == required_servers.length

    Rails.logger.info(
      "[McpOauthResumeService] Partial OAuth progress for session #{session.id}: " \
      "#{remaining.length} of #{required_servers.length} servers still need authorization"
    )

    session.update!(
      metadata: session.metadata.merge("oauth_required_servers" => remaining)
    )
  end
end
