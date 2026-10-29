# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# `precedence` / `place` without a `scheduling_class` on `PATCH
# /api/v1/sessions/:id`: Sessions::UpdatePrecedence's write, logged as the web
# rank editor and MCP's `change_precedence` log it, and kept in one save with
# the PATCH's other columns. (With a `scheduling_class` the rank is
# Sessions::UpdateSchedulingClass's — sessions_controller_scheduling_class_test.rb.)
class Api::V1::SessionsControllerPrecedenceTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  test "a precedence goes through Sessions::UpdatePrecedence and is logged" do
    session = spot_session(precedence: 5)
    calls = []
    real_call = Sessions::UpdatePrecedence.method(:call)
    spy = lambda do |**kwargs, &blk|
      calls << kwargs
      real_call.call(**kwargs, &blk)
    end

    Sessions::UpdatePrecedence.stub(:call, spy) do
      patch "/api/v1/sessions/#{session.id}", params: { precedence: 90 }, headers: @headers
    end

    assert_response :success
    assert_equal 1, calls.size
    assert_equal :rest, calls.first[:actor]
    assert_equal 90, session.reload.precedence
    assert_equal 90, JSON.parse(response.body)["session"]["precedence"]
    assert_equal [ "Precedence set via the REST API to 90 (was 5)" ], precedence_logs(session)
  end

  test "a place resolves against the live queue and logs the value it resolved to" do
    spot_session(precedence: 400)
    session = spot_session(precedence: 5)

    patch "/api/v1/sessions/#{session.id}",
      params: { place: SessionPrecedence::PLACE_TOP_OF_SPOT }, headers: @headers

    assert_response :success
    expected = 400 + SessionPrecedence::SLOT_GAP
    assert_equal expected, session.reload.precedence
    assert_equal [ "Precedence set via the REST API to #{expected} (was 5)" ], precedence_logs(session)
  end

  test "the rank the session already holds writes no log row" do
    session = spot_session(precedence: 1_000)

    patch "/api/v1/sessions/#{session.id}",
      params: { place: SessionPrecedence::PLACE_TOP_OF_SPOT }, headers: @headers
    assert_response :success
    patch "/api/v1/sessions/#{session.id}", params: { precedence: 1_000 }, headers: @headers
    assert_response :success

    assert_equal 1_000, session.reload.precedence
    assert_empty precedence_logs(session)
  end

  # Every after_commit reads only the last save's changes, so the rank, the goal
  # and the other columns have to be one UPDATE, each with its log row.
  test "a precedence alongside a goal and other columns is one save" do
    session = spot_session(precedence: 5)
    # Keyed on `saved_change_to_goal?`: a second save after the goal's would
    # leave it nothing to see.
    Session.any_instance.expects(:broadcast_goal_check_panel).at_least_once

    updates = count_session_updates do
      patch "/api/v1/sessions/#{session.id}",
        params: { precedence: 90, goal: "Ship it", is_autonomous: true, custom_metadata: { "k" => "v" } },
        headers: @headers, as: :json
    end

    assert_response :success
    assert_equal 1, updates
    session.reload
    assert_equal 90, session.precedence
    assert_equal "Ship it", session.goal
    assert session.is_autonomous
    assert_equal "v", session.custom_metadata["k"]
    logs = session.logs.pluck(:content)
    assert_includes logs, "Precedence set via the REST API to 90 (was 5)"
    assert_includes logs, "Goal set via the REST API"
  end

  test "a refused goal refuses the rank that came with it" do
    session = spot_session(precedence: 5)

    patch "/api/v1/sessions/#{session.id}",
      params: { place: SessionPrecedence::PLACE_TOP_OF_SPOT, goal: "x" * (Session::GOAL_MAX_LENGTH + 1) },
      headers: @headers, as: :json

    assert_response :unprocessable_entity
    session.reload
    assert_equal 5, session.precedence
    assert_nil session.goal
    assert_empty session.logs
  end

  test "a refused rank refuses the columns that came with it" do
    session = spot_session(precedence: 5)

    patch "/api/v1/sessions/#{session.id}",
      params: { precedence: SessionPrecedence::MAX + 1, goal: "Ship it", slug: "another-slug" },
      headers: @headers, as: :json

    assert_response :unprocessable_entity
    assert_match(/Precedence/, JSON.parse(response.body)["message"].to_s)
    session.reload
    assert_equal 5, session.precedence
    assert_nil session.goal
    assert_not_equal "another-slug", session.slug
    assert_empty session.logs
  end

  test "a blank precedence is the model's say-nothing, written as the default and logged" do
    session = spot_session(precedence: 5)

    patch "/api/v1/sessions/#{session.id}", params: { precedence: "" }, headers: @headers

    assert_response :success
    assert_equal SessionPrecedence::DEFAULT, session.reload.precedence
    assert_equal [ "Precedence set via the REST API to #{SessionPrecedence::DEFAULT} (was 5)" ], precedence_logs(session)
  end

  test "a non-integer precedence is a 422 and writes nothing" do
    session = spot_session(precedence: 5)

    patch "/api/v1/sessions/#{session.id}", params: { precedence: "urgent" }, headers: @headers

    assert_response :unprocessable_entity
    assert_equal 5, session.reload.precedence
    assert_empty session.logs
  end

  test "a PATCH without a rank writes no precedence log row" do
    session = spot_session(precedence: 5)

    patch "/api/v1/sessions/#{session.id}", params: { slug: "another-slug" }, headers: @headers

    assert_response :success
    assert_equal 5, session.reload.precedence
    assert_empty precedence_logs(session)
  end

  private

  def spot_session(precedence:)
    Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: precedence, status: :waiting
    )
  end

  def precedence_logs(session)
    session.logs.order(:created_at).pluck(:content).grep(/\APrecedence /)
  end

  def count_session_updates(&block)
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].match?(/\AUPDATE "sessions"/) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end
