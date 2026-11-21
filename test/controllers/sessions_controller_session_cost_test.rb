# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The session page's spend line: dollars, tokens, and what the dollars mean.
class SessionsControllerSessionCostTest < ActionDispatch::IntegrationTest
  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
  end

  def pi_session_with_usage
    session = Session.create!(title: "pi", prompt: "x", agent_runtime: "pi",
                              git_root: "https://github.com/test/repo.git", branch: "main",
                              config: { "model" => "openrouter/~x-ai/grok-latest" })
    SessionTokenUsage.create!(request_id: "pi:#{SecureRandom.uuid}:aaaa0001", model: "openrouter/~x-ai/grok-latest",
                              session_id: session.id, agent_root: "zimmer", agent_runtime: "pi",
                              called_at: 5.minutes.ago,
                              input_tokens: 60_851, output_tokens: 19_346, cache_read_tokens: 2_293_248)
    session
  end

  test "a Pi session shows its cost, its token count and that the money is owed" do
    session = pi_session_with_usage

    get session_url(session)

    assert_response :success
    assert_select "#session_#{session.id}_cost" do |line|
      assert_includes line.text, "$1.38"
      assert_includes line.text, "2.37M tokens"
      assert_match(/money owed/, line.attr("title").to_s)
      assert_match(/60,851 input, 19,346 output, 2,293,248 cache read/, line.attr("title").to_s)
    end
    assert_select "#session_#{session.id}_cost_badge", text: "$1.38"
  end

  test "a session with nothing stored keeps an empty, hidden target for the first broadcast" do
    session = sessions(:running)

    get session_url(session)

    assert_response :success
    assert_select "#session_#{session.id}_cost.hidden"
  end
end
