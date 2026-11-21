# frozen_string_literal: true

require "test_helper"

# A Pi session's spend reaches the ledger as each model response lands.
class TranscriptPollerPiUsageRefreshTest < ActiveJob::TestCase
  def poller_for(session) = TranscriptPollerService.new(session, file_system: Object.new)

  def assistant_with_usage
    { "type" => "message", "id" => "aaaa0001",
      "message" => { "role" => "assistant", "usage" => { "input" => 1, "output" => 2 } } }
  end

  def pi_session
    Session.create!(title: "pi", prompt: "x", agent_runtime: "pi",
                    git_root: "https://github.com/tadasant/zimmer.git", branch: "main")
  end

  test "a new usage-bearing Pi entry enqueues a refresh for that session" do
    session = pi_session

    assert_enqueued_with(job: PiSessionUsageRefreshJob, args: [ session.id ]) do
      poller_for(session).send(:refresh_pi_usage_if_billed, [ { "type" => "session" }, assistant_with_usage ])
    end
  end

  test "entries that carry no usage enqueue nothing" do
    session = pi_session
    tool_result = { "type" => "message", "id" => "b", "message" => { "role" => "toolResult" } }

    assert_no_enqueued_jobs(only: PiSessionUsageRefreshJob) do
      poller_for(session).send(:refresh_pi_usage_if_billed, [ tool_result, { "type" => "model_change" } ])
    end
  end

  test "a Claude Code session is left to the fleet sweep" do
    assert_no_enqueued_jobs(only: PiSessionUsageRefreshJob) do
      poller_for(sessions(:running)).send(:refresh_pi_usage_if_billed, [ assistant_with_usage ])
    end
  end
end
