# frozen_string_literal: true

require "test_helper"

# The session page's banners on the REST surface: `waiting` beside `session` on
# show, and `POST /sessions/:id/force_start`, the queued-turn banner's Force.
class Api::V1::SessionsWaitingTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  SLOTS = 2

  setup do
    @api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @api_key
    @headers = { "X-API-Key" => @api_key }

    GoodJob::Process.delete_all
    GoodJob::Job.delete_all
    @capsule = GoodJob::Process.create!(state: { "hostname" => "worker-1" })
  end

  teardown do
    GoodJob::Job.delete_all
    GoodJob::Process.delete_all
    ENV.delete("API_KEYS")
  end

  def with_pool(&block) = RunningTurns.stub(:worker_slots, SLOTS, &block)

  def session_in(status, **attrs)
    Session.create!({
      git_root: "https://github.com/t/r.git", prompt: "work", status: status,
      session_id: "cli-#{SecureRandom.hex(4)}", genesis: SessionGenesis::WEB_UI
    }.merge(attrs))
  end

  def turn_on_a_worker(session, started:)
    GoodJob::Job.create!(
      queue_name: "agents", job_class: "AgentSessionJob", active_job_id: SecureRandom.uuid,
      serialized_params: { "job_class" => "AgentSessionJob", "arguments" => [ session.id ] },
      performed_at: started, locked_at: started, locked_by_id: @capsule.id
    )
  end

  def saturate
    SLOTS.times.map { |i| session_in(:running).tap { |s| turn_on_a_worker(s, started: (SLOTS - i).minutes.ago) } }
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

  # --- GET /sessions/:id ------------------------------------------------------

  test "show carries waiting beside session, with no banners when there is nothing to say" do
    session = session_in(:needs_input)

    get "/api/v1/sessions/#{session.id}", headers: @headers

    assert_response :success
    body = response.parsed_body
    assert_equal({ "reasons" => [], "banners" => [] }, body["waiting"])
    assert_not body["session"].key?("waiting"), "`session` keeps one shape on every response"
  end

  test "show carries the spot hold banner in the page's words" do
    session = session_in(:waiting, scheduling_class: SessionGenesis::SPOT)
    session.update!(metadata: {
      SpotSessionHold::HELD_AT => 2.minutes.ago.iso8601,
      SpotSessionHold::HELD_REASON => "at_utilization_limit",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5-hour window at 87% of its 65% target.",
      SpotSessionHold::HELD_RETRY_AT => 10.minutes.from_now.iso8601,
      SpotSessionHold::HELD_COUNT => 1,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START
    })

    get "/api/v1/sessions/#{session.id}", headers: @headers

    assert_response :success
    waiting = response.parsed_body["waiting"]
    assert_equal [ { "mechanism" => "spot_hold", "label" => "a spot-gate hold (`at_utilization_limit`)",
                     "at" => session.metadata[SpotSessionHold::HELD_AT].then { Time.zone.parse(_1).utc.iso8601 },
                     "current" => true, "demoted" => false } ], waiting["reasons"]
    banner = waiting["banners"].sole
    assert_equal "spot_hold", banner["key"]
    assert_equal "warning", banner["tone"]
    assert_equal "Held for quota headroom", banner["headline"]
    assert_equal "Holding spot sessions: 5-hour window at 87% of its 65% target.", banner["body"].first
    assert_equal "update_scheduling_class", banner["action"]["kind"]
  end

  test "show offers Force on a queued turn, naming the turn it would stop" do
    _oldest, newest = saturate
    session = queued_session

    with_pool { get "/api/v1/sessions/#{session.id}", headers: @headers }

    assert_response :success
    banner = response.parsed_body["waiting"]["banners"].sole
    assert_equal "queued_turn", banner["key"]
    assert_equal({ "kind" => "force_start", "label" => "Force", "expected_victim_id" => newest.id },
                 banner["action"].except("confirm"))
  end

  # --- POST /sessions/:id/force_start ----------------------------------------

  test "force_start stops the newest turn, re-queues it, and says so" do
    _oldest, newest = saturate
    session = queued_session

    with_pool do
      assert_enqueued_with(job: AgentSessionJob) do
        post "/api/v1/sessions/#{session.id}/force_start", params: { expected_victim_id: newest.id }, headers: @headers
      end
    end

    assert_response :success
    body = response.parsed_body
    assert_equal session.id, body["session"]["id"]
    assert_match(/Session #{newest.id}'s turn was stopped and put back in the queue/, body["message"])
    assert newest.reload.waiting?
    assert_equal session.id, newest.metadata[Sessions::ForceTurnStart::FORCED_FOR_SESSION]
  end

  test "force_start refuses when the confirmed turn is no longer the one that would be stopped" do
    _oldest, newest = saturate
    session = queued_session

    with_pool do
      assert_no_enqueued_jobs(only: AgentSessionJob) do
        post "/api/v1/sessions/#{session.id}/force_start", params: { expected_victim_id: 424_242 }, headers: @headers
      end
    end

    assert_response :unprocessable_entity
    body = response.parsed_body
    assert_equal "Cannot force", body["error"]
    assert_match(/session 424242's — is no longer the one that would be stopped/, body["message"])
    assert newest.reload.running?, "the turn nobody confirmed is left alone"
  end

  test "force_start refuses when there is nothing to force" do
    turn_on_a_worker(session_in(:running), started: 1.minute.ago)
    session = queued_session

    with_pool do
      post "/api/v1/sessions/#{session.id}/force_start", params: { expected_victim_id: 424_242 }, headers: @headers
    end

    assert_response :unprocessable_entity
    assert_match(/Nothing to force/, response.body)
  end

  test "force_start refuses a session with no turn queued" do
    saturate
    session = session_in(:needs_input)

    with_pool do
      post "/api/v1/sessions/#{session.id}/force_start", params: { expected_victim_id: 424_242 }, headers: @headers
    end

    assert_response :unprocessable_entity
    assert_equal "Cannot force", response.parsed_body["error"]
  end

  test "force_start requires the victim the caller confirmed" do
    _oldest, newest = saturate
    session = queued_session

    with_pool { post "/api/v1/sessions/#{session.id}/force_start", headers: @headers }

    assert_response :unprocessable_entity
    assert_equal "Missing parameter", response.parsed_body["error"]
    assert_match(/expected_victim_id is required/, response.parsed_body["message"])
    assert newest.reload.running?
  end

  test "an agent forcing through REST is never its own victim" do
    oldest, newest = saturate
    session = queued_session

    with_pool do
      post "/api/v1/sessions/#{session.id}/force_start",
           params: { expected_victim_id: oldest.id, acting_session_id: newest.id }, headers: @headers
    end

    assert_response :success
    assert oldest.reload.waiting?
    assert newest.reload.running?, "the caller's own turn is not taken"
  end

  test "show still answers when a banner cannot be built" do
    session = session_in(:waiting, metadata: { "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED })

    AuthOutageParkService.stub(:pool_recovery_time, ->(_) { raise ActiveRecord::ConnectionNotEstablished, "down" }) do
      get "/api/v1/sessions/#{session.id}", headers: @headers
    end

    assert_response :success
    assert_empty response.parsed_body["waiting"]["banners"]
    assert_equal session.id, response.parsed_body["session"]["id"]
  end
end
