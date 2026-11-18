# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# A long read is CarPlay-ok: every mark stored as `laptop_only` + `long_read`,
# whoever wrote it, is flipped to `carplay_ok` + `long_read` once, and a
# laptop-only mark with any other reason is left alone.
class FlipLongReadCarplayMarksToCarplayOkTest < ActiveSupport::TestCase
  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Log.any_instance.stubs(:broadcast_append_to_timeline)

    @entry = PostDeployTask::Registry.find("20261118155842")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
  end

  test "flips every laptop-only long read, whatever its source, and nothing else" do
    set_at = 2.days.ago.change(usec: 0)
    auto = stored_mark("laptop_only", "long_read", source: "auto", line_count: 4, set_at: set_at)
    assistant = stored_mark("laptop_only", "long_read", source: "assistant", line_count: 2, set_at: set_at)
    credential = stored_mark("laptop_only", "credential", source: "auto")
    manual = stored_mark("laptop_only", "manual_steps", source: "assistant")
    no_reason = stored_mark("laptop_only", nil, source: "auto")
    already_ok = stored_mark("carplay_ok", "decision", source: "auto")
    untagged = a_session

    run, outcome = run_task

    assert_nil outcome
    assert_equal 2, run.stats["flipped"]
    assert_equal [ auto.id, assistant.id ].sort, run.stats["flipped_ids"]

    [ auto, assistant ].each do |session|
      session.reload
      assert_equal "carplay_ok", session.carplay_fit
      assert_equal "long_read", session.carplay_fit_reason
    end
    auto.reload
    assert_equal "auto", auto.carplay_fit_source, "the source is kept"
    assert_equal 4, auto.carplay_fit_line_count, "the transcript position is kept, so staleness is unchanged"
    assert_equal set_at, auto.carplay_fit_set_at
    assert_equal "assistant", assistant.reload.carplay_fit_source

    assert_equal [ "laptop_only", "credential" ], credential.reload.then { [ it.carplay_fit, it.carplay_fit_reason ] }
    assert_equal [ "laptop_only", "manual_steps" ], manual.reload.then { [ it.carplay_fit, it.carplay_fit_reason ] }
    assert_equal [ "laptop_only", nil ], no_reason.reload.then { [ it.carplay_fit, it.carplay_fit_reason ] }
    assert_equal [ "carplay_ok", "decision" ], already_ok.reload.then { [ it.carplay_fit, it.carplay_fit_reason ] }
    assert_nil untagged.reload.carplay_fit
  end

  test "an engaged session's auto mark becomes the sticky carplay mark, and a person's or agent's mark is noted on the timeline" do
    engaged = stored_mark("laptop_only", "long_read", source: "auto")
    engaged.update_columns(carplay_engaged_at: 1.hour.ago)
    engaged_human = stored_mark("laptop_only", "long_read", source: "human")
    engaged_human.update_columns(carplay_engaged_at: 1.hour.ago)
    plain_auto = stored_mark("laptop_only", "long_read", source: "auto")

    run_task

    assert_equal [ "carplay_ok", "carplay" ], engaged.reload.then { [ it.carplay_fit, it.carplay_fit_source ] }
    assert engaged.carplay_fit_sticky?
    assert_equal [ "carplay_ok", "human" ], engaged_human.reload.then { [ it.carplay_fit, it.carplay_fit_source ] }
    assert_equal 1, engaged_human.logs.where("content LIKE ?", "CarPlay fit re-read as CarPlay-ok%").count
    assert_includes engaged_human.logs.last.content, "The human mark said Laptop only (a long read)."
    assert_equal 0, engaged.logs.count + plain_auto.logs.count, "an automatic mark is not logged"
  end

  test "a second run flips nothing" do
    stored_mark("laptop_only", "long_read", source: "auto")
    run_task

    run, _outcome = run_task

    assert_equal 0, run.stats["flipped"]
    assert_equal 0, Session.where(carplay_fit: "laptop_only", carplay_fit_reason: "long_read").count
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

  # Written past validation, the way a mark from before the rule sits in the table.
  def stored_mark(fit, reason, source:, line_count: 0, set_at: Time.current)
    session = a_session
    session.update_columns(carplay_fit: fit, carplay_fit_reason: reason, carplay_fit_source: source,
                           carplay_fit_line_count: line_count, carplay_fit_set_at: set_at)
    session
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
end
