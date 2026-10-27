# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The job the post-deploy backfill enqueues once per unmarked session. The
# property that matters is that it is a no-op for every row that no longer
# needs it, so a re-enqueue, a retry or a human who got there first cost nothing.
class CarplayFitBackfillJobTest < ActiveSupport::TestCase
  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code", status: :needs_input, prompt: "p",
      git_root: "https://github.com/test/repo.git", branch: "main"
    }.merge(attrs))
  end

  test "classifies an unmarked needs_input session" do
    session = make_session
    CarplayFitClassifier.expects(:call).with { |s| s.id == session.id }.returns(CarplayFitClassifier::Result.new(outcome: :applied, message: "ok"))

    CarplayFitBackfillJob.perform_now(session.id)
  end

  test "leaves alone a session that is already marked, no longer resting, or gone" do
    CarplayFitClassifier.expects(:call).never

    CarplayFitBackfillJob.perform_now(make_session(carplay_fit: "carplay_ok", carplay_fit_source: "human", carplay_fit_line_count: 0).id)
    CarplayFitBackfillJob.perform_now(make_session(status: :running).id)
    CarplayFitBackfillJob.perform_now(-1)
  end
end
