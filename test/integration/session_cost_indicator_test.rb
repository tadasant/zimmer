# frozen_string_literal: true

require "test_helper"

# The muted per-session cost indicator, on the dashboard card and on the session
# detail page.
class SessionCostIndicatorTest < ActionDispatch::IntegrationTest
  setup do
    @session = sessions(:needs_input)
    SessionTokenUsage.create!(
      request_id: "req_#{SecureRandom.hex(6)}",
      model: "claude-opus-5",
      session_id: @session.id,
      agent_root: "zimmer",
      called_at: 1.hour.ago,
      cache_read_tokens: 2_000_000
    )
  end

  test "the dashboard card carries the session's cost" do
    get root_path

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@session)}", 1,
      "the seeded session should be on the dashboard for this assertion to mean anything"
    assert_match "$1.00", response.body
  end

  test "the session detail page carries the session's cost" do
    get session_path(@session)

    assert_response :success
    assert_match "$1.00", response.body
  end

  test "the dashboard costs one query for every card's figure" do
    # An N+1 here would be invisible in correctness and expensive in production:
    # the dashboard renders every card in one response.
    other = sessions(:running)
    SessionTokenUsage.create!(
      request_id: "req_#{SecureRandom.hex(6)}", model: "claude-opus-5",
      session_id: other.id, agent_root: "zimmer", called_at: 1.hour.ago, cache_read_tokens: 1_000_000
    )

    cost_queries = 0
    counter = lambda do |*, payload|
      cost_queries += 1 if payload[:sql].to_s.include?("session_token_usages") &&
                           payload[:sql].to_s.include?("GROUP BY")
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get root_path }

    assert_response :success
    assert_operator cost_queries, :<=, 4,
      "one grouped query per rendered collection, not one per card"
  end

  test "a session with no recorded usage shows no figure rather than a confident zero" do
    SessionTokenUsage.delete_all

    get session_path(@session)

    assert_response :success
    assert_no_match "$0.00", response.body
  end
end
