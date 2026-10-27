# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The first drive after the deploy: every session already resting on the board
# with a blurb but no mark gets one classification enqueued, once. Both
# directions are tested — too broad spends a completion on a session nobody
# would be shown, too narrow leaves the board untagged, which is the state the
# feature exists to end.
class BackfillCarplayFitFromStatusSummariesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    SessionStatusSummary.any_instance.stubs(:broadcast_panel_replacement)

    @entry = PostDeployTask::Registry.find("20261027170500")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
  end

  test "enqueues one classification per unmarked needs_input session with a ready blurb, and nothing else" do
    wanted = a_session
    ready!(wanted)
    marked = a_session(carplay_fit: "carplay_ok", carplay_fit_source: "human", carplay_fit_line_count: 0)
    ready!(marked)
    running = a_session(status: :running)
    ready!(running)
    blurbless = a_session
    failed_blurb = a_session
    SessionStatusSummary.create!(session: failed_blurb, state: "failed", summary: nil)
    fork = a_session(metadata: { SessionStatusSummaryGenerator::FORK_MARKER => wanted.id })
    ready!(fork)

    run, outcome = nil
    assert_enqueued_with(job: CarplayFitBackfillJob, args: [ wanted.id ]) do
      run, outcome = run_task
    end

    assert_nil outcome, "the sweep must finish rather than ask to be resumed"
    enqueued = enqueued_jobs.select { |j| j["job_class"] == "CarplayFitBackfillJob" }.map { |j| j["arguments"].first }
    assert_equal [ wanted.id ], enqueued
    assert_equal 1, run.stats["enqueued"]
    [ marked, running, blurbless, failed_blurb, fork ].each do |session|
      assert_not_includes enqueued, session.id
    end
  end

  test "a second run finds nothing to do" do
    run, _outcome = run_task

    assert_equal 0, run.stats["enqueued"]
  end

  private

  def run_task
    run = PostDeployTaskRun.create!(
      version: "#{@entry.version}-#{SecureRandom.hex(4)}",
      name: @entry.task_name,
      status: "pending"
    )
    assert run.claim!(owner: "test"), "the ledger row must be claimable"
    outcome = @task_class.new(run: run, logger: Rails.logger).up
    [ run.reload, outcome ]
  end

  def a_session(**attrs)
    Session.create!({
      prompt: "work #{SecureRandom.hex(4)}",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    }.merge(attrs))
  end

  def ready!(session)
    SessionStatusSummary.create!(session: session, state: "ready", summary: "Merge the PR.", transcript_line_count: 0, generated_at: Time.current)
  end
end
