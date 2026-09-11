# frozen_string_literal: true

require "test_helper"

class CostScopeTest < ActiveSupport::TestCase
  test "no params is the whole fleet" do
    scope = CostScope.from_params({})

    assert_predicate scope, :fleet?
    assert_equal({}, scope.to_params)
    assert_equal "all agent roots", scope.label
  end

  test "an agent root round-trips" do
    scope = CostScope.from_params(agent_root: "zimmer-router")

    assert_predicate scope, :agent_root?
    assert_not_predicate scope, :fleet?
    assert_equal({ agent_root: "zimmer-router" }, scope.to_params)
    assert_equal "zimmer-router", scope.label
  end

  test "a session id round-trips as an integer" do
    scope = CostScope.from_params(session_id: "42")

    assert_predicate scope, :session?
    assert_equal 42, scope.session_id
    assert_equal({ session_id: 42 }, scope.to_params)
    assert_equal "session #42", scope.label
  end

  # Same precedence `get_costs` applies to the same pair of arguments: a session
  # sits inside a root, so the narrower of the two is what was asked for.
  test "a session id wins over an agent root when both are given" do
    scope = CostScope.new(agent_root: "zimmer-router", session_id: 42)

    assert_predicate scope, :session?
    assert_nil scope.agent_root
    assert_equal({ session_id: 42 }, scope.to_params)
  end

  # `"nope".to_i` is 0 — a real id shape. Narrowing the page to a session that
  # cannot exist is worse than ignoring the parameter.
  test "a session id that is not digits falls back to the fleet rather than to session 0" do
    [ "nope", "12abc", "-1", "1.5", "" ].each do |raw|
      scope = CostScope.from_params(session_id: raw)

      assert_predicate scope, :fleet?, "#{raw.inspect} should not scope anything"
      assert_nil scope.session_id
    end
  end

  test "a blank agent root is the fleet" do
    assert_predicate CostScope.from_params(agent_root: ""), :fleet?
    assert_predicate CostScope.from_params(agent_root: "   "), :fleet?
  end

  test "each slice gets its own cache token" do
    tokens = [
      CostScope.new,
      CostScope.new(agent_root: "zimmer-router"),
      CostScope.new(agent_root: "issue-work-gate"),
      CostScope.new(session_id: 1),
      CostScope.new(session_id: 2)
    ].map(&:cache_token)

    assert_equal tokens.uniq, tokens
  end

  test "narrowing filters session usage and feature rows the same way" do
    session = sessions(:running)
    mine = SessionTokenUsage.create!(request_id: "req_mine", model: "claude-opus-5",
                                     agent_root: "zimmer-router", session_id: session.id,
                                     called_at: 1.hour.ago, output_tokens: 10)
    SessionTokenUsage.create!(request_id: "req_theirs", model: "claude-opus-5",
                              agent_root: "issue-work-gate", session_id: sessions(:archived).id,
                              called_at: 1.hour.ago, output_tokens: 10)
    TokenUsageFeature.create!(request_id: mine.request_id, feature: "goal", session_id: session.id,
                              agent_root: "zimmer-router", model: mine.model, called_at: mine.called_at,
                              output_tokens: 4)

    by_root = CostScope.new(agent_root: "zimmer-router")
    assert_equal [ "req_mine" ], by_root.narrow(SessionTokenUsage.all).pluck(:request_id)
    assert_equal [ "goal" ], by_root.narrow(TokenUsageFeature.all).pluck(:feature)

    by_session = CostScope.new(session_id: session.id)
    assert_equal [ "req_mine" ], by_session.narrow(SessionTokenUsage.all).pluck(:request_id)
    assert_equal [ "goal" ], by_session.narrow(TokenUsageFeature.all).pluck(:feature)
  end

  # Ad hoc spend is Zimmer's own inference, made outside any session. It carries
  # no agent root, so a root-scoped view of it is empty rather than unfiltered —
  # leaving it unfiltered would put the whole fleet's ad hoc bill under one root's
  # heading.
  test "ad hoc usage is excluded from an agent-root scope and kept for the session it was about" do
    session = sessions(:running)
    AdhocTokenUsage.create!(request_id: "req_titling", source: "headless_inference",
                            model: "claude-haiku-4-5", called_at: 1.hour.ago, output_tokens: 20,
                            subject_session_id: session.id)
    AdhocTokenUsage.create!(request_id: "req_probe", source: "cli_status_probe",
                            model: "claude-haiku-4-5", called_at: 1.hour.ago, output_tokens: 20)

    assert_equal 2, CostScope.new.narrow_adhoc(AdhocTokenUsage.all).count
    assert_equal 0, CostScope.new(agent_root: "zimmer-router").narrow_adhoc(AdhocTokenUsage.all).count
    assert_equal [ "req_titling" ],
                 CostScope.new(session_id: session.id).narrow_adhoc(AdhocTokenUsage.all).pluck(:request_id)
  end
end
