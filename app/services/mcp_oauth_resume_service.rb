# Decides what a completed MCP OAuth authorization does to the session it was
# started from: resume it if it was parked on that authorization, and otherwise
# tell a live session — and its reader — that the grant is back.
#
# When a session needs OAuth for one or more MCP servers it cannot start: it is
# parked in a blocked state and its required servers are recorded in
# metadata["oauth_required_servers"]. The user authorizes each server one at a
# time. This service is invoked after each authorization completes and decides
# whether the session can now continue.
#
# The session's original intent — its prompt — is already durably stored on the
# Session record, so resuming a session whose FIRST turn was blocked is a matter
# of re-queuing the initial run via AgentSessionJob.enqueue_new_session, which
# replays that prompt. Its attachments are durable too, but on the volume rather
# than in the job, so they are read back and put on the replay explicitly; see
# #replayable_attachments for why that read is gated and the restart doors'
# equivalent is not. This service owns the "should we resume yet, and resume
# exactly once" decision.
#
# == Which prompt the resume delivers ==
#
# The original prompt is the right answer only when the turn that was blocked is
# the first one. `oauth_required` is also reachable for a session that is owed a
# message a human already sent — AgentSessionJob's follow-up gate blocks that
# exact turn, and the **Edit MCP servers** / **Edit plugins** escalations fail an
# idle session that may be holding an undelivered one. Replaying the stored
# prompt there answers a question nobody asked and drops the message with nothing
# saying so (#887).
#
# So the resume asks first whether the session is owed a turn —
# `pending_follow_up_prompt`, the marker every recovery path already reads as
# "handed to a job, not yet delivered" — and delivers THAT through
# Session#deliver_follow_up! when it is. The one case it cannot honour is a
# session with no runtime `session_id` for a follow-up to continue, and that case
# is stated in the session's own timeline rather than quietly answered with a
# different prompt: a silent substitution is the defect itself.
#
# A session is considered OAuth-blocked when it is either:
#   - failed with metadata["failure_reason"] == "oauth_required", or
#   - waiting with metadata["oauth_required_servers"] still present
#
# Behavior:
#   - All required servers authorized AND no active pending flows remain
#       -> atomically clear the OAuth metadata and re-queue the session: the turn
#          it is owed if one is standing (running, with that follow-up), and
#          otherwise the original run (waiting). Returns :resumed.
#   - Some servers still need authorization (or a pending flow is still active)
#       -> trim oauth_required_servers to those still outstanding so the UI
#          reflects progress, leaving the session blocked. Returns :partial.
#   - The session is not blocked but is live (running or needs_input) and uses
#       the server that was just authorized
#       -> re-inject the fresh credential into the runtime store, record the
#          server under metadata["mcp_oauth_reconnect"], and say so in the
#          session's own timeline. Returns :reconnect_pending.
#   - The session is not (or no longer) blocked and none of the above applies
#       -> Returns :not_blocked.
#
# == Why a live session gets a notice rather than a resume ==
#
# Claude Code reads its MCP servers once, at launch. A running agent process
# therefore cannot be handed a connection it did not start with, and there is no
# honest way to make a re-authorization take hold mid-turn: the only mechanism
# that would is killing the process and starting another one, which is the
# double-process hazard #400 documents. A needs_input session is at rest and does
# self-heal, but only one turn later — the follow-up spawn re-runs
# `gate_and_inject_oauth!` and injects the fresh credential.
#
# So neither live state gets a respawn from here. What both get is the thing that
# was actually missing: the credential on disk immediately, and a statement that
# the next turn is what reconnects. `enqueue_new_session` is deliberately NOT
# reachable from this branch — it replays the session's original prompt, which is
# the wrong thing to say in the middle of a conversation.
#
# Exactly-once resume is guaranteed by running the whole decision under a row
# lock (with_lock = SELECT ... FOR UPDATE + reload). Once the first caller
# resumes the session, the OAuth metadata is cleared as part of the same locked
# transaction, so a concurrent or retried callback re-reads the post-resume
# state, sees the session is no longer blocked, and does nothing.
class McpOauthResumeService
  # Cap on the undelivered prompt echoed into the session's timeline when the
  # resume cannot deliver it. Generous, because this copy is the one a human
  # reads and re-sends by hand — but bounded, because the timeline is a UI.
  UNDELIVERED_PROMPT_LOG_MAX_CHARS = 4_000

  # @param session [Session] the session to evaluate for resumption
  # @param authorized_server [String, nil] the name of the server whose flow just
  #   completed. Only the live-session branch needs it — a resume is decided from
  #   the session's own `oauth_required_servers` — so it stays optional, and a
  #   caller that omits it simply gets no reconnect notice.
  def initialize(session, authorized_server: nil)
    @session = session
    @authorized_server = authorized_server
  end

  # @return [Symbol] :resumed, :partial, :reconnect_pending, or :not_blocked
  def call
    # Read the volume BEFORE taking the row lock, the way the restart doors read
    # before their transaction: sniffing an image's media type reads its bytes,
    # and a slow volume must not hold a session row open. The gate below is
    # re-asked under the lock, against the reloaded row.
    attachments = replayable_attachments

    outcome = @session.with_lock do
      if blocked?
        remaining = servers_still_needing_oauth

        if remaining.empty? && pending_flows.none?
          resume!(attachments)
          :resumed
        else
          record_partial_progress(remaining)
          :partial
        end
      else
        :not_blocked
      end
    end

    # Outside the lock on purpose: the live branch writes the runtime credential
    # store, and a file write must not hold a session row open (the same reason
    # the attachment read above happens before the lock).
    return outcome unless outcome == :not_blocked

    notify_live_session
  end

  private

  attr_reader :session, :authorized_server

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

  # The not-blocked branch for a session that is live and uses the server whose
  # grant was just renewed. Puts the fresh token where the next spawn reads it,
  # then records the server so the session page can say the grant is back and the
  # next turn is what picks it up.
  #
  # @return [Symbol] :reconnect_pending when a notice was recorded, else :not_blocked
  def notify_live_session
    return :not_blocked if authorized_server.blank?
    return :not_blocked unless session.running? || session.needs_input?
    return :not_blocked unless session.user_selected_mcp_servers.include?(authorized_server)

    reinject_credentials
    record_reconnect_pending
    :reconnect_pending
  end

  # Writes the session's OAuth credentials to the runtime store now, rather than
  # leaving the freshly-authorized one to be discovered at the next spawn. The
  # spawn gate injects too, so this is not what makes the next turn work — it is
  # what lets the runtime retry the connection with a live token in the window
  # before then, and it clears the runtime's needs-auth memo for the same reason
  # `McpOauthCredentialInjector#inject_credentials!` does.
  #
  # Note what it reaches: the injector collects EVERY server the session wires,
  # not only the one just authorized, so it may reconcile and refresh a token an
  # in-flight turn is using. That is the same pass the spawn gate makes on every
  # spawn, and the refreshes it performs are bounded by
  # `McpOauthService::REQUEST_TIMEOUT`.
  #
  # Best-effort: a missing clone directory or an unwritable store must not turn a
  # successful authorization into a 500 on the callback.
  def reinject_credentials
    McpOauthCredentialInjector.new(
      session,
      working_directory: session.metadata&.dig("working_directory")
    ).inject_credentials!
  rescue => e
    Rails.logger.warn(
      "[McpOauthResumeService] Could not re-inject credentials for " \
      "#{authorized_server.inspect} on session #{session.id}: #{e.class}: #{e.message}"
    )
  end

  # Adds the server to metadata["mcp_oauth_reconnect"]["servers"] and, the first
  # time a given server lands there, says so in the session's timeline.
  #
  # `merge_metadata!` rather than `update!` because this can run against a session
  # that is mid-turn, where a whole-column read-modify-write would erase whatever
  # the job wrote in between. That protects the keys this caller never names; it
  # does not serialize two writers of THIS key, and two servers authorized at
  # once are exactly that — both would read the same list, and the later write
  # would drop the earlier server. So the read and the write are taken under a row
  # lock, which also makes a repeated callback idempotent: the list is a set, and
  # both the timeline line and the app log are written only when the set grows.
  #
  # A different lock from the one #call takes: that one is released before the
  # runtime store is written, and re-entering it here is a plain DB round trip.
  def record_reconnect_pending
    session.with_lock do
      known = session.mcp_oauth_reconnect_servers
      next if known.include?(authorized_server)

      session.merge_metadata!(
        Session::MCP_OAUTH_RECONNECT_KEY => {
          "servers" => known + [ authorized_server ],
          "authorized_at" => Time.current.iso8601
        }
      )

      Rails.logger.info(
        "[McpOauthResumeService] #{authorized_server} re-authorized for live session " \
        "#{session.id} (#{session.status}); it reconnects on the next turn"
      )

      session.logs.create!(
        level: "info",
        content: "#{authorized_server} is authorized again. This session's agent loaded its " \
          "MCP servers when it started and cannot pick up a new connection mid-run, so the " \
          "next message is what reconnects it."
      )
    end
  end

  def resume!(attachments)
    # Re-asked under the lock, against the row `with_lock` reloaded. The read
    # above happened before it, and a session that started producing a
    # transcript in between is no longer replaying a first turn.
    images, files = session.transcript.present? ? [ [], [] ] : attachments

    # A turn the session is still owed outranks the stored prompt: replaying the
    # first turn on top of it is how the human's message got dropped (#887).
    held = deliverable_follow_up
    return resume_with_follow_up!(held, images, files) if held

    session.merge_metadata!(
      "oauth_complete" => true,
      "failure_reason" => nil,
      "oauth_required_servers" => nil
    )
    session.update!(status: "waiting")

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

  # The turn this session is still owed, when there is one and it can actually be
  # delivered as a continuation.
  #
  # `pending_follow_up_prompt` means "a prompt was handed to a job and the job has
  # not delivered it". Three routes reach `failed` + `oauth_required` with one
  # standing: AgentSessionJob's follow-up gate, which hands this turn's prompt
  # back rather than letting it die with the job argument that held it, and the
  # **Edit MCP servers** / **Edit plugins** escalations, which fail an idle
  # session whose stamped-but-undelivered prompt they never touch. In all three
  # the session is owed a message a human sent, and `enqueue_new_session` would
  # answer a different question instead.
  #
  # @return [String, nil] the raw prompt to deliver, or nil to resume the stored
  #   prompt exactly as before
  def deliverable_follow_up
    prompt = session.metadata&.dig("pending_follow_up_prompt").presence
    return nil if prompt.blank?
    return prompt if session.session_id.present?

    # No runtime conversation to continue: AgentSessionJob reclassifies a
    # follow-up for a session with no `session_id` as a fresh start and runs the
    # stored prompt, so delivering it here would substitute one prompt for
    # another without saying so — the defect, in the other direction. Resume the
    # first turn, keep the message where it can be read and re-sent, and say
    # plainly that it was not delivered.
    Rails.logger.warn(
      "[McpOauthResumeService] Session #{session.id} has a pending follow-up but no runtime session id; " \
      "resuming its original prompt and leaving the follow-up undelivered"
    )
    session.logs.create!(
      level: "warning",
      content: "OAuth authorization complete, but this session never started a conversation for a " \
        "follow-up to continue — it is resuming its original prompt instead. The message that was " \
        "blocked has NOT been delivered; it is kept on the session and can be sent again:\n\n" \
        "#{prompt.to_s.truncate(UNDELIVERED_PROMPT_LOG_MAX_CHARS)}"
    )
    nil
  end

  # Resume by delivering the turn the session was blocked on, through the one
  # shared delivery path — which resumes the session to `running`, re-stamps the
  # prompt as pending so the recovery paths can still find it, enqueues the job
  # and records `running_job_id`.
  #
  # Raw text, deliberately: `deliver_follow_up!`'s job wraps the goal block around
  # whatever it is given, so replaying `active_follow_up_prompt` — the expanded
  # form — would hand the agent its goal twice (the reasoning
  # Sessions::RestartUnstartedTurn spells out for the same three keys).
  def resume_with_follow_up!(prompt, images, files)
    session.merge_metadata!(
      "oauth_complete" => true,
      "failure_reason" => nil,
      "oauth_required_servers" => nil
    )

    session.deliver_follow_up!(prompt, clear_metadata_keys: Session::SIGTERM_RETRY_METADATA_KEYS)

    Rails.logger.info(
      "[McpOauthResumeService] All OAuth flows complete for session #{session.id}, " \
      "delivering the follow-up that was blocked on it rather than replaying the original prompt"
    )

    session.logs.create!(
      level: "info",
      content: "OAuth authorization complete: sending the message that was blocked on it. " \
        "This session's original prompt is not replayed — it has already had its turn."
    )

    # The attachments read off the volume are the FIRST turn's, and this turn is
    # not the first one, so they are not put on it — the same "somebody else's
    # attachment is worse than none" rule Sessions::FirstTurnAttachments states.
    # Reachable only for a session with a runtime id and an empty transcript, so
    # it is rare enough to be worth saying out loud when it happens.
    stranded = Sessions::FirstTurnAttachments.carrying_clause(images, files)
    return if stranded.blank?

    session.logs.create!(
      level: "info",
      content: "This session's first-turn attachments#{stranded.sub(/\A, carrying /, ' — ')} — are not " \
        "carried on that message: they belong to the first turn, not to this one."
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
  # here, because three routes set it on a session that has already run:
  # Sessions::UpdateCatalogSelection, when an `mcp_servers` or `catalog_plugins`
  # change adds a server needing authorization to a live session — reachable from
  # the web UI, the REST endpoints and `action_session` alike; AgentSessionJob's
  # follow-up branch, under "Follow-up blocked: OAuth authorization required for
  # MCP servers"; and AgentSessionJob#check_and_handle_mcp_failure, the
  # post-spawn classifier that #authorized? below already names. Sessions::FirstTurnAttachments reads
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

    session.merge_metadata!("oauth_required_servers" => remaining)
  end
end
