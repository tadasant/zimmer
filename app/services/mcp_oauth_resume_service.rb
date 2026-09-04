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
# AgentSessionJob.enqueue_new_session, which replays that prompt. Its
# attachments are durable too, but on the volume rather than in the job, so they
# are read back and put on the replay explicitly; see #replayable_attachments
# for why that read is gated and the restart doors' equivalent is not. This
# service owns the "should we resume yet, and resume exactly once" decision.
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
    # Read the volume BEFORE taking the row lock, the way the restart doors read
    # before their transaction: sniffing an image's media type reads its bytes,
    # and a slow volume must not hold a session row open. The gate below is
    # re-asked under the lock, against the reloaded row.
    attachments = replayable_attachments

    @session.with_lock do
      return :not_blocked unless blocked?

      remaining = servers_still_needing_oauth

      if remaining.empty? && pending_flows.none?
        resume!(attachments)
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

  def resume!(attachments)
    # Re-asked under the lock, against the row `with_lock` reloaded. The read
    # above happened before it, and a session that started producing a
    # transcript in between is no longer replaying a first turn.
    images, files = session.transcript.present? ? [ [], [] ] : attachments

    session.update!(
      status: "waiting",
      metadata: session.metadata.merge(
        "oauth_complete" => true,
        "failure_reason" => nil,
        "oauth_required_servers" => nil
      )
    )

    AgentSessionJob.enqueue_new_session(session.id, images: images.presence, files: files.presence)

    carrying = Sessions::FirstTurnAttachments.carrying_clause(images, files)

    Rails.logger.info(
      "[McpOauthResumeService] All OAuth flows complete for session #{session.id}, " \
      "auto-resuming original intent#{carrying}"
    )

    # What the turn carries goes in the session's own timeline, not only in the
    # app log — an answer only a shell on the box can reach is not an answer. It
    # is written only when there IS something to say: an ordinary resume carries
    # nothing, and saying so every time would bury the times it does.
    return if carrying.blank?

    session.logs.create!(
      level: "info",
      content: "OAuth authorization complete: replaying this session's first turn#{carrying}."
    )
  end

  # The attachments to put back on the replayed turn — which is the session's
  # own first-turn attachments, or nothing at all.
  #
  # The replay is `enqueue_new_session`, so what it delivers is the stored prompt
  # — the original intent. AgentSessionJob reads attachments ONLY out of its job
  # arguments and never re-reads the volume, so replaying that prompt without
  # them delivers "here is the screenshot, fix this" with the prompt and without
  # the screenshot (#789).
  #
  # == Why this is gated where the restart doors are not
  #
  # Restart from scratch is gated on `failed_before_initial_prompt? &&
  # !setup_complete?`, so it knows nothing was ever delivered. `oauth_required`
  # being a member of PRE_PROMPT_FAILURE_REASONS does NOT buy the same knowledge
  # here, because four routes set it on a session that has already run:
  # SessionsController#update_mcp_servers and #update_catalog_plugins, when a
  # human adds a server to a live session; AgentSessionJob's follow-up branch,
  # under "Follow-up blocked: OAuth authorization required for MCP servers"; and
  # AgentSessionJob#check_and_handle_mcp_failure, the post-spawn classifier that
  # #authorized? below already names. Sessions::FirstTurnAttachments reads
  # everything on the volume minus what the queue owns, and on such a session
  # that set includes attachments earlier turns already consumed — re-delivering
  # them would put the first turn's screenshot on a much later one.
  #
  # A blank transcript is what separates the two: it is the same half of
  # Session#never_ran? that means "no turn has reached an agent", without the
  # `session_id` half, which is already stamped by the time the fresh-clone spawn
  # reaches its OAuth gate and so would refuse a genuine first turn.
  #
  # It is a proxy for a decision the job makes for itself and states differently
  # — `is_resume` there is `runtime_started && session_id.present? &&
  # (follow_up_prompt.present? || reusing_existing_clone)`. The two diverge only
  # in the conservative direction: an already-run session whose clone has since
  # been swept takes the job's fresh-start branch and replays its prompt, and
  # this gate gives it no attachments to go with it.
  #
  # @return [Array(Array<Hash>, Array<Hash>)] images, files
  def replayable_attachments
    return [ [], [] ] if session.transcript.present?

    Sessions::FirstTurnAttachments.for(session)
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
