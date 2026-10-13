# frozen_string_literal: true

require "test_helper"

# The session page's banners as data, for the iOS app — and, for every banner
# the web draws, the proof that the data says what the page says: each test
# renders the partial beside the service and requires the headline and every
# paragraph to appear in the HTML's text. A wording change on one side and not
# the other fails here rather than on somebody's phone.
class Sessions::WaitingExplanationTest < ActionView::TestCase
  SLOTS = 2

  setup do
    freeze_time
    GoodJob::Process.delete_all
    GoodJob::Job.delete_all
    @capsule = GoodJob::Process.create!(state: { "hostname" => "worker-1" })
  end

  teardown do
    GoodJob::Job.delete_all
    GoodJob::Process.delete_all
  end

  def session_in(status, metadata: {}, **attrs)
    Session.create!({
      git_root: "https://github.com/test/repo.git", prompt: "work", status: status,
      session_id: "cli-#{SecureRandom.hex(4)}", genesis: SessionGenesis::WEB_UI, metadata: metadata
    }.merge(attrs))
  end

  def explain(session) = Sessions::WaitingExplanation.call(session)

  def banner(session, key)
    found = explain(session)[:banners].find { |b| b[:key] == key }
    assert found, "expected a #{key} banner, got #{explain(session)[:banners].map { |b| b[:key] }.inspect}"
    found
  end

  def keys(session) = explain(session)[:banners].map { |b| b[:key] }

  # The partial's visible text, whitespace collapsed the way a reader sees it.
  def partial_text(partial, **locals)
    Nokogiri::HTML.fragment(render(partial: partial, locals: locals)).text.squish
  end

  def assert_partial_says(banner, partial, **locals)
    text = partial_text(partial, **locals)
    [ banner[:headline], *banner[:body] ].each do |line|
      assert_includes text, line.squish, "#{partial} does not say what the #{banner[:key]} banner says"
    end
  end

  def hold_metadata(held_at: 2.minutes.ago, retry_at: 10.minutes.from_now, reason: "at_utilization_limit",
                    turn: SpotSessionHold::TURN_START)
    {
      SpotSessionHold::HELD_AT => held_at.iso8601,
      SpotSessionHold::HELD_REASON => reason,
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5-hour window at 87% of its 65% target.",
      SpotSessionHold::HELD_RETRY_AT => retry_at.iso8601,
      SpotSessionHold::HELD_COUNT => 3,
      SpotSessionHold::HELD_TURN => turn
    }
  end

  def with_pool(&block) = RunningTurns.stub(:worker_slots, SLOTS, &block)

  def turn_on_a_worker(session, started:)
    GoodJob::Job.create!(
      queue_name: "agents", job_class: "AgentSessionJob", active_job_id: SecureRandom.uuid,
      serialized_params: { "job_class" => "AgentSessionJob", "arguments" => [ session.id ] },
      performed_at: started, locked_at: started, locked_by_id: @capsule.id
    )
  end

  def queued_session
    session = session_in(:waiting)
    GoodJob::Job.create!(
      queue_name: "agents", job_class: "AgentSessionJob", active_job_id: SecureRandom.uuid,
      serialized_params: { "job_class" => "AgentSessionJob", "arguments" => [ session.id ] },
      created_at: 30.seconds.ago
    )
    session
  end

  # --- nothing to say -----------------------------------------------------------

  test "a session with nothing on its row has no banners and no reasons" do
    assert_equal({ reasons: [], banners: [] }, explain(session_in(:needs_input)))
  end

  # --- spot hold and pause ------------------------------------------------------

  test "a hold at the starting line reads as the page reads it, with the priority button" do
    session = session_in(:waiting, scheduling_class: SessionGenesis::SPOT, metadata: hold_metadata)
    spot = banner(session, "spot_hold")

    assert_equal "Held for quota headroom", spot[:headline]
    assert_equal "warning", spot[:tone]
    assert_includes spot[:body].last, "Next check"
    assert_includes spot[:body].join(" "), "it will start on its own once the gate lets it."
    assert_equal({ kind: "update_scheduling_class", label: "Make this session priority",
                   scheduling_class: SessionGenesis::PRIORITY }, spot[:action])
    assert_equal [ "spot_hold" ], explain(session)[:reasons].map { |r| r[:mechanism] }
    assert_partial_says spot, "sessions/spot_hold_banner", agent_session: session
  end

  test "a hold on a resume names the next turn" do
    session = session_in(:waiting, scheduling_class: SessionGenesis::SPOT,
                                   metadata: hold_metadata(turn: SpotSessionHold::TURN_RESUME))
    spot = banner(session, "spot_hold")

    assert_equal "Next turn held for quota headroom", spot[:headline]
    assert_partial_says spot, "sessions/spot_hold_banner", agent_session: session
  end

  test "a hold the session's class has overtaken says so and offers no button" do
    session = session_in(:waiting, scheduling_class: SessionGenesis::PRIORITY, metadata: hold_metadata)
    spot = banner(session, "spot_hold")

    assert_equal "Spot hold no longer applies — this session is priority", spot[:headline]
    assert_includes spot[:body], SpotSessionHold::PROMOTED_SENTENCE
    assert_nil spot[:action]
    assert_partial_says spot, "sessions/spot_hold_banner", agent_session: session
  end

  test "an overdue hold is named as stalled" do
    session = session_in(:waiting, scheduling_class: SessionGenesis::SPOT,
                                   metadata: hold_metadata(held_at: 11.hours.ago, retry_at: 10.hours.ago,
                                                           reason: "fleet_at_cap"))
    spot = banner(session, "spot_hold")

    assert_equal "Spot hold stalled — its re-check never fired", spot[:headline]
    assert spot[:details][:overdue]
    assert_partial_says spot, "sessions/spot_hold_banner", agent_session: session
  end

  test "a hold a newer auth-outage park supersedes carries the superseded line and drops the re-check" do
    session = session_in(:waiting, scheduling_class: SessionGenesis::SPOT, metadata: hold_metadata.merge(
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => 1.minute.ago.iso8601
    ))
    explanation = explain(session)
    spot = banner(session, "spot_hold")

    assert_includes spot[:body].join(" "), "the auth-outage park above was recorded later"
    assert_includes spot[:body].join(" "), "it resumes from the outage above"
    assert_not spot[:body].any? { |line| line.include?("Next check") }
    assert_equal %w[auth_outage_park spot_hold], explanation[:reasons].map { |r| r[:mechanism] }
    assert_equal [ true, false ], explanation[:reasons].map { |r| r[:current] }
    assert_equal %w[auth_outage spot_hold], keys(session)
    assert_partial_says spot, "sessions/spot_hold_banner", agent_session: session
  end

  test "a demoted hold says nothing is coming to re-arm it" do
    session = session_in(:waiting, scheduling_class: SessionGenesis::SPOT, metadata: hold_metadata(
      held_at: 3.hours.ago, retry_at: 2.hours.ago
    ).merge("auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
            "auth_outage_parked_at" => 5.hours.ago.iso8601))
    spot = banner(session, "spot_hold")

    assert_includes spot[:body].join(" "), "nothing is coming to re-arm this hold"
    assert explain(session)[:reasons].find { |r| r[:mechanism] == "spot_hold" }[:demoted]
    assert_partial_says spot, "sessions/spot_hold_banner", agent_session: session
  end

  test "a ceiling pause, a preemption and a deliberate park each read as the page reads them" do
    {
      "at_utilization_limit" => "Paused mid-run for quota headroom",
      SpotSessionPause::PREEMPTED_REASON => "Preempted by a priority session",
      SpotSessionPause::QUEUED_REASON => "Waiting in the spot queue"
    }.each do |reason, headline|
      session = session_in(:waiting, scheduling_class: SessionGenesis::SPOT, metadata: {
        SpotSessionPause::PAUSED_AT => 1.minute.ago.iso8601,
        SpotSessionPause::PAUSED_REASON => reason,
        SpotSessionPause::PAUSED_DETAIL => "Paused: the 5-hour window reached its target."
      })
      spot = banner(session, "spot_hold")

      assert_equal headline, spot[:headline]
      assert_equal "spot_pause", spot[:details][:mechanism]
      assert_partial_says spot, "sessions/spot_hold_banner", agent_session: session
    end
  end

  # --- auth outage and the quota notice -----------------------------------------

  test "an auth-outage park says who resumes it" do
    session = session_in(:waiting, metadata: {
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => 1.minute.ago.iso8601
    })
    outage = banner(session, "auth_outage")

    assert_equal "Quota exceeded across all accounts", outage[:headline]
    assert_includes outage[:body].first, AuthOutageWakeAuthority.resume_sentence(session)
    assert_partial_says outage, "sessions/auth_outage_banner", agent_session: session
  end

  test "a login outage names the login, not the quota" do
    session = session_in(:waiting, metadata: { "auth_outage_reason" => "not_logged_in" })
    outage = banner(session, "auth_outage")

    assert_equal "No usable login available", outage[:headline]
    assert_partial_says outage, "sessions/auth_outage_banner", agent_session: session
  end

  test "the earliest pool reset is named when it is in the future" do
    session = session_in(:waiting, metadata: {
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => 1.minute.ago.iso8601
    })
    resets = 2.hours.from_now

    AuthOutageParkService.stub(:pool_recovery_time, resets) do
      outage = banner(session, "auth_outage")
      assert_includes outage[:body].first, "The pool's earliest reset is"
      assert_equal resets.utc.iso8601, outage[:details][:pool_recovers_at]
      assert_partial_says outage, "sessions/auth_outage_banner", agent_session: session
    end
  end

  test "a quota limit that did not exhaust the pool is the header's inline notice" do
    session = session_in(:needs_input, metadata: { "last_quota_limit_at" => 1.minute.ago.iso8601 })
    notice = banner(session, "quota_limit_paused")

    assert_equal "Paused", notice[:headline]
    assert_equal [ Sessions::WaitingExplanation::QUOTA_LIMIT_NOTICE ], notice[:body]

    parked = session_in(:needs_input, metadata: { "last_quota_limit_at" => 1.minute.ago.iso8601,
                                                  "auth_outage_reason" => "not_logged_in" })
    assert_not_includes keys(parked), "quota_limit_paused", "the outage banner carries the parked case"
  end

  # --- starvation lane ----------------------------------------------------------

  test "a starvation admission uses the admission's own sentence" do
    session = session_in(:running, metadata: {
      SpotSessionHold::STARVATION_ADMITTED_AT => 5.minutes.ago.iso8601,
      SpotSessionHold::STARVATION_ADMITTED_AFTER_HOLDS => 12,
      SpotSessionHold::STARVATION_ADMITTED_AFTER_SECONDS => 26.hours.to_i
    })
    admitted = banner(session, "starvation_admission")

    assert_equal "Admitted by the starvation lane", admitted[:headline]
    assert_partial_says admitted, "sessions/spot_starvation_admission", agent_session: session
  end

  # --- queued for a worker ------------------------------------------------------

  test "a queued turn behind a full pool offers Force against the newest turn" do
    _oldest = session_in(:running).tap { |s| turn_on_a_worker(s, started: 2.minutes.ago) }
    newest = session_in(:running).tap { |s| turn_on_a_worker(s, started: 1.minute.ago) }
    session = queued_session

    with_pool do
      queued = banner(session, "queued_turn")

      assert_equal "Queued for a worker", queued[:headline]
      assert_equal "info", queued[:tone]
      assert_equal "force_start", queued[:action][:kind]
      assert_equal newest.id, queued[:action][:expected_victim_id]
      assert_match(/Stop session ##{newest.id}'s turn/, queued[:action][:confirm])
      assert queued[:details][:force][:available]
      assert_equal newest.id, queued[:details][:force][:victim][:id]
      assert_equal [ "turn_queued" ], explain(session)[:reasons].map { |r| r[:mechanism] }
      assert_partial_says queued, "sessions/queued_turn_banner", agent_session: session
    end
  end

  test "a queued turn with nothing to force says why and carries no action" do
    turn_on_a_worker(session_in(:running), started: 1.minute.ago)
    session = queued_session

    with_pool do
      queued = banner(session, "queued_turn")

      assert_nil queued[:action]
      assert_not queued[:details][:force][:available]
      assert_match(/Nothing to force/, queued[:body].last)
      assert_partial_says queued, "sessions/queued_turn_banner", agent_session: session
    end
  end

  test "a hold beside a queued turn says the queued turn is the reason" do
    session = queued_session
    session.update!(scheduling_class: SessionGenesis::SPOT, metadata: hold_metadata(held_at: 5.minutes.ago))

    with_pool do
      assert_equal %w[spot_hold queued_turn], keys(session)
      spot = banner(session, "spot_hold")
      assert_includes spot[:body].join(" "), "its turn has been handed over and is queued for a worker"
      assert_partial_says spot, "sessions/spot_hold_banner", agent_session: session
    end
  end

  # --- MCP OAuth ----------------------------------------------------------------

  test "a renewed grant on a live session offers the reconnect message the page sends" do
    session = session_in(:needs_input, metadata: { Session::MCP_OAUTH_RECONNECT_KEY => { "servers" => [ "linear" ] } })
    reconnect = banner(session, "mcp_oauth_reconnect")

    assert_equal "Authorization complete — reconnects on the next turn", reconnect[:headline]
    assert_equal({ kind: "follow_up", label: "Reconnect now",
                   prompt: "linear has been re-authorized, so its MCP tools are available again. " \
                           "Pick up where you left off." }, reconnect[:action])
    assert_equal [ "linear" ], reconnect[:details][:servers]
    assert_partial_says reconnect, "sessions/mcp_oauth_reconnect_banner", agent_session: session
    assert_includes render(partial: "sessions/mcp_oauth_reconnect_banner", locals: { agent_session: session }),
                    reconnect[:action][:prompt]
  end

  test "a session that needs OAuth sends the person to the browser" do
    session = session_in(:failed, metadata: {
      "failure_reason" => "oauth_required",
      "oauth_required_servers" => [ { "server_name" => "linear", "server_url" => "https://mcp.linear.app/sse" } ]
    })
    required = banner(session, "mcp_oauth_required")

    assert_equal "OAuth Authorization Required", required[:headline]
    assert_equal [ { server_name: "linear", server_url: "https://mcp.linear.app/sse" } ], required[:details][:servers]
    assert_equal({ kind: "open_in_browser", label: "Authorize in the browser", path: session_path(session) },
                 required[:action])
    assert_partial_says required, "sessions/mcp_oauth_required_banner", agent_session: session
  end

  # --- lost approval ------------------------------------------------------------

  test "a lost approval request names what it was" do
    session = session_in(:needs_input, metadata: {
      "lost_elicitation" => { "reason" => "lost", "summary" => "Approve deploying to prod", "at" => 2.minutes.ago.iso8601 }
    })
    lost = banner(session, "lost_elicitation")

    assert_equal "Approval request lost", lost[:headline]
    assert_equal "Requested: Approve deploying to prod", lost[:body].last
    assert_equal 2.minutes.ago.utc.iso8601, lost[:details][:at]
    assert_partial_says lost, "elicitations/lost_elicitation_banner", session: session
  end

  test "an expired approval request says it expired" do
    session = session_in(:needs_input, metadata: { "lost_elicitation" => { "reason" => "expired" } })
    lost = banner(session, "lost_elicitation")

    assert_equal "Approval request expired", lost[:headline]
    assert_partial_says lost, "elicitations/lost_elicitation_banner", session: session
  end

  # --- pending wake (no web banner) ---------------------------------------------

  test "a session asleep on a wake-up says when it wakes" do
    session = session_in(:needs_input)
    wake_at = 90.minutes.from_now.change(sec: 0)
    Sessions::ScheduleWakeUp.call(session: session, wake_at: wake_at.utc.strftime("%Y-%m-%dT%H:%M:%S"),
                                  prompt: "check back", timezone: "UTC")
    wake = banner(session.reload, "pending_wake")

    assert_equal "info", wake[:tone]
    assert_equal wake_at.utc.iso8601, wake[:details][:at]
    assert_equal "it is paused until #{wake_at.utc.iso8601}", wake[:details][:phrase]
    assert_equal "Asleep until #{wake_at.utc.strftime('%b %-d, %H:%M')} UTC", wake[:headline]
  end

  # --- order --------------------------------------------------------------------

  test "banners come in the order the page stacks them" do
    session = session_in(:needs_input, metadata: {
      "last_quota_limit_at" => 1.minute.ago.iso8601,
      Session::MCP_OAUTH_RECONNECT_KEY => { "servers" => [ "linear" ] },
      SpotSessionHold::STARVATION_ADMITTED_AT => 5.minutes.ago.iso8601,
      "lost_elicitation" => { "reason" => "expired" }
    })

    assert_equal %w[quota_limit_paused starvation_admission mcp_oauth_reconnect lost_elicitation], keys(session)
  end
end
