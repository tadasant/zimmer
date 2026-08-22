# frozen_string_literal: true

require "test_helper"

# The muted cost indicator on the dashboard cards and the session detail page.
class SessionTokenUsageCostBySessionTest < ActiveSupport::TestCase
  def usage(session_id:, **overrides)
    SessionTokenUsage.create!({
      request_id: "req_#{SecureRandom.hex(6)}",
      model: "claude-opus-5",
      session_id: session_id,
      agent_root: "zimmer",
      called_at: 1.hour.ago,
      cache_read_tokens: 100_000
    }.merge(overrides))
  end

  test "totals every session in one query, not one query per card" do
    # The dashboard renders up to a few hundred cards in one response. A per-card
    # lookup would be a per-card round trip, which is the bug this method exists
    # to prevent.
    a = sessions(:active_session)
    b = sessions(:running)
    usage(session_id: a.id)
    usage(session_id: a.id)
    usage(session_id: b.id)

    result = nil
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name].to_s.in?([ "SCHEMA", "TRANSACTION" ]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      result = SessionTokenUsage.cost_by_session([ a.id, b.id ])
    end

    assert_equal 1, queries
    assert_operator result[a.id], :>, result[b.id]
    assert_in_delta result[a.id], result[b.id] * 2, 0.0001
  end

  test "a session with no stored usage comes back as zero rather than missing" do
    # The caller caches this hash. A missing key would make it re-query for the
    # same card on every render.
    result = SessionTokenUsage.cost_by_session([ sessions(:active_session).id ])

    assert_equal({ sessions(:active_session).id => 0.0 }, result)
  end

  test "asking for nothing queries nothing" do
    assert_equal({}, SessionTokenUsage.cost_by_session([]))
    assert_equal({}, SessionTokenUsage.cost_by_session(nil))
  end
end
