# frozen_string_literal: true

module Sessions
  # The session page's "why is it waiting" and recovery banners, as data.
  #
  # == Why this exists
  #
  # The web page answers "why is this session sitting here, and what can I do
  # about it" with a stack of partials, each of which reads the row and its
  # neighbours (the ranking, the `agents` lane, the account pool, the OAuth
  # grants) and turns them into a sentence. The iOS app needs the same answers,
  # and the only honest way to give them is to send the sentences — a client that
  # re-derived them would be a second reading of the precedence SessionWaitingReason
  # exists to keep in one place (tadasant/zimmer#642), and would drift the first
  # time a partial's wording changed.
  #
  # So this reads exactly what the partials read, through the same services, and
  # says it in the same words. `test/services/sessions/waiting_explanation_test.rb`
  # renders each partial next to this and fails when a line either says is
  # missing from the other, or the control's label or confirmation differs, so
  # the two cannot drift silently.
  #
  # == The shape
  #
  #   {
  #     reasons: [ { mechanism:, label:, at:, current:, demoted: } ],  # SessionWaitingReason, ranked
  #     banners: [ { key:, tone:, headline:, body: [String], details: {}, action: nil | {} } ]
  #   }
  #
  # Banners come in the order the desktop session header stacks them, then the
  # lost-approval banner that sits above the composer. `tone` is the banner's
  # colour on the web: amber and orange are "warning", sky and blue are "info".
  # `details` carries the structured facts a client may want to format itself
  # (times as ISO 8601, server lists, the force victim); the prose already says
  # them. `action` is the one control the banner carries, or nil:
  #
  #   * `update_scheduling_class` — `PATCH /api/v1/sessions/:id` with `scheduling_class`
  #   * `force_start` — `POST /api/v1/sessions/:id/force_start` with `expected_victim_id`
  #   * `follow_up` — `POST /api/v1/sessions/:id/follow_up` with `prompt`
  #   * `open_in_browser` — the web page at `path`, for a flow only a browser can finish
  #
  # `pending_wake` is the one banner the web page does not draw. Its wording is
  # this class's own, built on Session#pending_wake_phrase, the sentence the
  # restart refusal and AgentSessionJob's stand-down log use.
  class WaitingExplanation
    include ActionView::Helpers::DateHelper

    INFO = "info"
    WARNING = "warning"

    # The session header's inline line for a quota limit that did NOT exhaust the
    # pool. Shared with `_session_metadata.html.erb`, which renders it after a
    # bold "Paused:".
    QUOTA_LIMIT_NOTICE = "Account quota limit reached — retry skipped (resets at time shown in error)"

    # @param session [Session]
    # @param now [Time] one clock for every relative time in the answer
    # @return [Hash]
    def self.call(session, now: Time.current)
      new(session, now: now).call
    end

    # The message the reconnect button sends. Shared with
    # `_mcp_oauth_reconnect_banner.html.erb`, so the web button and the app's say
    # the same thing to the agent.
    def self.reconnect_prompt(servers)
      "#{servers.to_sentence} #{servers.one? ? 'has' : 'have'} been re-authorized, " \
        "so #{servers.one? ? 'its' : 'their'} MCP tools are available again. " \
        "Pick up where you left off."
    end

    def initialize(session, now: Time.current)
      @session = session
      @now = now
    end

    def call
      reading = SessionWaitingReason.for(session)

      {
        reasons: reasons(reading),
        banners: [
          build("quota_limit_paused") { quota_limit_banner },
          build("auth_outage") { auth_outage_banner },
          build("spot_hold") { spot_banner(reading) },
          build("starvation_admission") { starvation_admission_banner },
          build("queued_turn") { queued_turn_banner(reading) },
          build("mcp_oauth_reconnect") { mcp_oauth_reconnect_banner },
          build("mcp_oauth_required") { mcp_oauth_required_banner },
          build("lost_elicitation") { lost_elicitation_banner },
          build("pending_wake") { pending_wake_banner }
        ].compact
      }
    end

    private

    attr_reader :session, :now

    def reasons(reading)
      return [] if reading.nil?

      reading.all.map do |mechanism|
        {
          mechanism: mechanism.key.to_s,
          label: mechanism.label,
          at: iso(mechanism.at),
          current: reading.current?(mechanism),
          demoted: mechanism.demoted?
        }
      end
    end

    # One banner, or nil when it has nothing to say or could not be built. Each
    # builder reads something different — the account pool, the `agents` lane,
    # the OAuth grants, the trigger table — and one of them failing must cost
    # that banner, not the GET /sessions/:id it rides on.
    def build(key)
      yield
    rescue StandardError => e
      Rails.logger.warn("[Sessions::WaitingExplanation] Could not build the #{key} banner for session " \
                        "#{session.id} (#{e.class}: #{e.message}) — leaving it out")
      nil
    end

    def banner(key, tone:, headline:, body:, details: {}, action: nil)
      { key: key, tone: tone, headline: headline, body: body.compact, details: details, action: action }
    end

    def metadata
      session.metadata || {}
    end

    def iso(time)
      time&.utc&.iso8601
    end

    # --- _session_metadata.html.erb: the inline quota notice -------------------

    def quota_limit_banner
      return nil unless session.needs_input?
      return nil if metadata["last_quota_limit_at"].blank? || metadata["auth_outage_reason"].present?

      banner("quota_limit_paused", tone: WARNING, headline: "Paused", body: [ QUOTA_LIMIT_NOTICE ],
             details: { last_quota_limit_at: metadata["last_quota_limit_at"] })
    end

    # --- _auth_outage_banner.html.erb ------------------------------------------

    def auth_outage_banner
      reason = metadata["auth_outage_reason"]
      return nil if reason.blank?

      quota = reason == AuthOutageParkService::QUOTA_EXHAUSTED
      recovers_at = AuthOutageParkService.pool_recovery_time(session)
      cause = if quota
        "Every #{RuntimeRegistry.label_for(session.agent_runtime)} account is over its quota, so there is nothing to rotate into."
      else
        "The runtime reported \"Not logged in\" and re-injecting credentials did not fix it."
      end
      reset = if recovers_at && recovers_at > now
        "The pool's earliest reset is #{recovers_at.utc.strftime('%b %-d, %H:%M')} UTC " \
          "(#{distance_of_time_in_words(now, recovers_at)} from now)."
      end

      banner(
        "auth_outage",
        tone: WARNING,
        headline: quota ? "Quota exceeded across all accounts" : "No usable login available",
        body: [ [ cause, "This session is parked. It resumes when #{AuthOutageWakeAuthority.resume_sentence(session)}", reset ].compact.join(" ") ],
        details: { reason: reason, parked_at: metadata["auth_outage_parked_at"], pool_recovers_at: iso(recovers_at) }
      )
    end

    # --- _spot_hold_banner.html.erb --------------------------------------------

    # Every branch below is the partial's, in the partial's order; see the
    # comments there for why each one is where it is.
    def spot_banner(reading)
      spot_reason = reading&.spot
      return nil if spot_reason.nil?

      hold = SpotSessionHold.record_for(session)
      pause_detail = metadata[SpotSessionPause::PAUSED_DETAIL]
      return nil if hold&.detail.blank? && pause_detail.blank?

      paused_mid_run = spot_reason.key == SessionWaitingReason::SPOT_PAUSE || hold&.detail.blank?
      superseded_by_park = !reading.current?(spot_reason) && reading.current.dormancy?
      queued_turn_supersedes = reading.current&.key == SessionWaitingReason::TURN_QUEUED
      queued_by_user = SpotSessionPause.queued_by_user?(session)
      preempted = SpotSessionPause.preempted?(session)
      promoted = !paused_mid_run && SpotSessionHold.superseded_by_promotion?(session)

      body = [ paused_mid_run ? pause_detail : hold.detail ]
      body << SpotSessionHold::PROMOTED_SENTENCE if promoted
      if queued_turn_supersedes
        body << "This is not why the session is waiting right now: its turn has been handed over and is " \
                "queued for a worker, so it runs as soon as a thread frees up. The hold below is the " \
                "record of how it got here."
      end
      if superseded_by_park
        body << if spot_reason.demoted?
          "This is not why the session is waiting now: the account pool is what it is waiting on, and " \
          "nothing is coming to re-arm this hold — the spot-hold sweep skips a session that also " \
          "carries an auth-outage park."
        else
          "This is not why the session is waiting now: the auth-outage park above was recorded later, " \
          "and the account pool is what it is waiting on."
        end
      end
      body << hold.as_of_sentence(now: now) if !paused_mid_run && hold
      body << hold_waiting_paragraph(hold) if !paused_mid_run && !promoted && !superseded_by_park && hold
      body << "This is a #{session.priority_class} session (genesis #{session.genesis_key}, " \
              "#{session.scheduling_class_source}). It has not been cancelled — " +
              spot_resume_clause(hold, paused_mid_run:, superseded_by_park:, queued_by_user:, preempted:, promoted:)
      body << hold.recheck_sentence(now: now) if !paused_mid_run && hold && !superseded_by_park

      banner(
        "spot_hold",
        tone: WARNING,
        headline: spot_headline(hold, paused_mid_run:, queued_by_user:, preempted:, promoted:),
        body: body,
        details: {
          mechanism: spot_reason.key.to_s,
          current: reading.current?(spot_reason),
          hold_reason: hold&.reason,
          held_at: iso(hold&.held_at),
          retry_at: iso(hold&.retry_at),
          overdue: hold&.overdue?(now: now) || false,
          priority_class: session.priority_class
        },
        action: (promoted ? nil : { kind: "update_scheduling_class", label: "Make this session priority",
                                    scheduling_class: SessionGenesis::PRIORITY })
      )
    end

    def spot_headline(hold, paused_mid_run:, queued_by_user:, preempted:, promoted:)
      if queued_by_user then "Waiting in the spot queue"
      elsif preempted then "Preempted by a priority session"
      elsif paused_mid_run then "Paused mid-run for quota headroom"
      elsif hold&.overdue?(now: now) then "Spot hold stalled — its re-check never fired"
      elsif promoted then "Spot hold no longer applies — this session is priority"
      elsif hold&.reason == "fleet_at_cap" then "Held for a free session slot"
      elsif hold&.turn == SpotSessionHold::TURN_RESUME then "Next turn held for quota headroom"
      else "Held for quota headroom"
      end
    end

    def hold_waiting_paragraph(hold)
      sentence = hold.waiting_sentence(now: now)
      return nil if sentence.nil?

      ceiling = AppSetting.current.spot_starvation_age_ceiling
      clause = if hold.starved?(ceiling: ceiling, now: now)
        "That is past the #{ceiling.inspect} starvation age ceiling: the starvation lane admits it " \
          "at its next re-check, as soon as no other starvation-admitted spot session has a turn in flight."
      elsif !hold.lane_applies?
        "It is held for a free session slot, which the starvation lane does not override: priority work " \
          "is meant to crowd spot work out, and the hold clears as soon as any running session ends."
      elsif ceiling.nil?
        "The starvation lane is off, so nothing bounds this wait."
      else
        "The starvation lane admits it once it has waited #{ceiling.inspect}, if the gate is still " \
          "holding it then."
      end
      "#{sentence} #{clause}"
    end

    def spot_resume_clause(hold, paused_mid_run:, superseded_by_park:, queued_by_user:, preempted:, promoted:)
      if superseded_by_park
        "it resumes from the outage above, once the account pool recovers."
      elsif queued_by_user
        "it was parked in the queue deliberately, with no wake-up time, and it resumes " \
          "when a Claude account is under both quota targets and a slot is free, ahead of everything " \
          "ranked below precedence #{session.precedence}."
      elsif preempted
        "it gave its session slot to a priority session, and it resumes from the spot queue — " \
          "highest precedence first — once the fleet is back under its concurrency limit and a " \
          "Claude account is under both quota targets. It waits in the same queue as the sessions " \
          "the budget ceiling paused, on the same resume decision."
      elsif paused_mid_run
        "it was already running when a window reached its target, and it resumes on its own " \
          "once utilization falls #{SpotGateService::RESUME_MARGIN_PCT} points below it."
      elsif promoted && hold&.overdue?(now: now)
        "the gate is done with it, but the re-check that was carrying its turn never " \
          "fired — so it is waiting on Zimmer's spot-hold sweep to put a turn back on it, " \
          "not on the gate."
      elsif promoted
        "the gate is done with it: the turn it already has queued runs without being " \
          "asked again, and this record is cleared the moment it does."
      elsif hold&.turn == SpotSessionHold::TURN_RESUME
        "the turn it was woken for is queued and runs on its own once the gate lets it."
      else
        "it will start on its own once the gate lets it."
      end
    end

    # --- _spot_starvation_admission.html.erb -----------------------------------

    def starvation_admission_banner
      admission = SpotSessionHold.starvation_admission_for(session)
      return nil if admission.nil?

      banner("starvation_admission", tone: WARNING, headline: "Admitted by the starvation lane",
             body: [ admission.sentence(running: session.running?, now: now) ],
             details: { admitted_at: iso(admission.admitted_at) })
    end

    # --- _queued_turn_banner.html.erb ------------------------------------------

    def queued_turn_banner(reading)
      queued = reading&.current
      return nil unless queued&.key == SessionWaitingReason::TURN_QUEUED

      slots = RunningTurns.worker_slots
      body = [
        "This session has been handed a turn and is waiting for #{queued.label}.",
        "Nothing is stuck and nobody needs to act. Zimmer runs #{slots} agent turns at once, and this one " \
          "starts as soon as a thread frees up. Running means a worker is executing a turn, so a session " \
          "queued behind the pool reads Waiting."
      ]

      force = Sessions::ForceTurnStart.preview(session)
      action = nil
      if force&.available?
        victim = force.victim
        age = force.victim_age ? "#{distance_of_time_in_words(force.victim_age)} ago" : "an unknown time ago"
        body << "All #{slots} threads are busy. Force takes one by stopping the turn that started most recently — " \
                "session ##{victim.id}, #{victim.priority_class}, started #{age}. That turn is not cancelled: it is " \
                "put straight back in the queue and runs again as soon as a thread frees up. What it loses is the " \
                "tool call it is in the middle of."
        action = {
          kind: "force_start",
          label: "Force",
          expected_victim_id: victim.id,
          confirm: "Stop session ##{victim.id}'s turn (#{victim.priority_class}, started #{age}) to free a worker " \
                   "thread for session ##{session.id}?\n\nIts work on disk survives and its turn goes back in the " \
                   "queue, but the tool call it is in the middle of is lost — and Zimmer cannot tell what that is."
        }
      elsif force
        body << force.message
      end

      banner(
        "queued_turn",
        tone: INFO,
        headline: "Queued for a worker",
        body: body,
        details: {
          queued_at: iso(queued.at),
          worker_slots: slots,
          force: force && {
            available: force.available?,
            victim: force.victim && { id: force.victim.id, title: force.victim.title, priority_class: force.victim.priority_class },
            victim_turn_age_seconds: force.victim_age&.to_i,
            message: force.message
          }
        },
        action: action
      )
    end

    # --- _mcp_oauth_reconnect_banner.html.erb ----------------------------------

    def mcp_oauth_reconnect_banner
      servers = session.mcp_oauth_reconnect_servers
      return nil unless servers.any? && (session.running? || session.needs_input?)

      body = "Zimmer has stored the renewed grant for #{servers.to_sentence}, and the next agent process this " \
             "session starts will use it. This session's agent loaded its MCP servers when it started and cannot " \
             "pick up a new connection mid-run, so those tools stay missing until it runs again. " +
             (session.running? ? "The agent is mid-turn, so a message sent now queues and reconnects on the turn after it." : "Send a message to reconnect.")

      banner(
        "mcp_oauth_reconnect",
        tone: INFO,
        headline: "Authorization complete — reconnects on the next turn",
        body: [ body ],
        details: { servers: servers },
        action: {
          kind: "follow_up",
          label: session.running? ? "Queue a reconnect message" : "Reconnect now",
          prompt: self.class.reconnect_prompt(servers)
        }
      )
    end

    # --- _mcp_oauth_required_banner.html.erb -----------------------------------

    # OAuth is a browser round-trip (redirect to the provider, callback to the
    # web app), so the action sends the person to the session page, where the
    # Authorize buttons are.
    def mcp_oauth_required_banner
      return nil unless session.failed? && metadata["failure_reason"] == "oauth_required"

      servers = McpOauthServerAuthorization.still_needing_authorization(metadata["oauth_required_servers"] || [])
      return nil if servers.none?

      banner(
        "mcp_oauth_required",
        tone: WARNING,
        headline: "OAuth Authorization Required",
        body: [ "The following MCP servers require OAuth authorization before the session can start. " \
                "Click \"Authorize\" for each server to grant access." ],
        details: {
          servers: servers.map do |info|
            { server_name: info["server_name"] || info[:server_name], server_url: info["server_url"] || info[:server_url] }
          end
        },
        action: { kind: "open_in_browser", label: "Authorize in the browser",
                  path: Rails.application.routes.url_helpers.session_path(session) }
      )
    end

    # --- elicitations/_lost_elicitation_banner.html.erb ------------------------

    def lost_elicitation_banner
      lost = session.lost_elicitation
      return nil if lost.blank?

      expired = lost["reason"] == "expired"
      body = [
        if expired
          "Nobody answered before the request timed out. The MCP server was told expired, so the agent " \
            "continued without approval."
        else
          "The round-trip never completed — the MCP server stopped waiting, or its response was lost. " \
            "This session is not blocked on it any more; reply below to tell the agent how to proceed."
        end
      ]
      body << "Requested: #{lost['summary'].truncate(200)}" if lost["summary"].present?

      banner(
        "lost_elicitation",
        tone: WARNING,
        headline: expired ? "Approval request expired" : "Approval request lost",
        body: body,
        details: { reason: lost["reason"], summary: lost["summary"], at: iso(session.lost_elicitation_at) }
      )
    end

    # --- no web banner: the wake the session is asleep on ----------------------

    # `waiting` only: a running session that armed a wake mid-turn is not asleep
    # on it, and a headline saying so would be false until the turn ends.
    # `armed_one_time_wake?` for the reason the REST follow-up's `pending_wake`
    # gives: an unreadable trigger table must read as "no wake", never as a
    # promise that the session wakes itself.
    def pending_wake_banner
      return nil unless session.waiting? && session.armed_one_time_wake?

      at = session.pending_wake_at
      phrase = session.pending_wake_phrase(at)
      banner(
        "pending_wake",
        tone: INFO,
        headline: at ? "Asleep until #{at.utc.strftime('%b %-d, %H:%M')} UTC" : "Asleep on a wake-up",
        body: [ "#{phrase.upcase_first}. It wakes on its own; a message sent now reaches " \
                "it without cancelling the wake-up." ],
        details: { at: iso(at), phrase: phrase }
      )
    end
  end
end
