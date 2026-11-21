# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "json"

class PiSessionUsageRefreshJobTest < ActiveJob::TestCase
  def pi_session(model: "~x-ai/grok-latest")
    uuid = SecureRandom.uuid
    entries = [
      { "type" => "session", "version" => 3, "id" => uuid, "timestamp" => "2026-11-21T13:56:37.791Z" },
      { "type" => "message", "id" => "aaaa0001", "timestamp" => "2026-11-21T14:00:00.000Z",
        "message" => { "role" => "assistant", "provider" => "openrouter", "model" => model,
                       "usage" => { "input" => 100, "output" => 50, "cacheRead" => 1_000, "cacheWrite" => 0 } } }
    ]
    Session.create!(
      title: "pi", prompt: "x", agent_runtime: "pi", git_root: "https://github.com/tadasant/zimmer.git",
      branch: "main", session_id: uuid,
      transcript: entries.map { |e| JSON.generate(e) }.join("\n") + "\n",
      metadata: { "agent_root_key" => "zimmer" }
    )
  end

  test "sweeps the one session into the ledger and repaints its cost" do
    session = pi_session
    Session.any_instance.expects(:broadcast_cost).once

    assert_equal 1, PiSessionUsageRefreshJob.perform_now(session.id)
    assert_equal 1, SessionTokenUsage.where(session_id: session.id).count
  end

  test "a second sweep adds nothing and repaints nothing" do
    session = pi_session
    PiSessionUsageRefreshJob.perform_now(session.id)
    Session.any_instance.expects(:broadcast_cost).never

    assert_equal 0, PiSessionUsageRefreshJob.perform_now(session.id)
  end

  test "is a no-op for a session that is not on Pi, or no longer exists" do
    assert_nil PiSessionUsageRefreshJob.perform_now(sessions(:running).id)
    assert_nil PiSessionUsageRefreshJob.perform_now(-1)
  end

  test "broadcast_cost renders the cost line and the header badge" do
    session = pi_session
    PiSessionUsageRefreshJob.perform_now(session.id)
    rendered = []
    fake = Object.new
    fake.define_singleton_method(:broadcast_html) { |target:, **, &block| rendered << [ target, block.call ] }
    session.define_singleton_method(:broadcaster) { fake }

    session.broadcast_cost

    cost_html = rendered.to_h.fetch("session_#{session.id}_cost")
    assert_includes cost_html, "1.2K tokens"
    assert_includes cost_html, "money owed"
    badge_html = rendered.to_h.fetch("session_#{session.id}_cost_badge")
    assert_includes badge_html, %(id="session_#{session.id}_cost_badge")
    assert_includes badge_html, "$0.001"
  end
end
