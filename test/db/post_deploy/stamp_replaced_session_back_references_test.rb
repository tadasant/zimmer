# frozen_string_literal: true

require "test_helper"

# The retroactive half of https://github.com/tadasant/zimmer/issues/801.
#
# The refusal that stops a superseded session being resumed reads the
# REPLACEMENT's `custom_metadata`, which every existing replacement already
# carries — so nothing here is load-bearing for correctness. What this repairs is
# readability: session 11924 still shows nothing pointing at 11931, so a human
# opening its page, or an agent reading it through `get_session`, is told nothing
# about where the work went. Sessions replaced from now on are stamped at
# creation; this is the same stamp applied backwards.
#
# Both directions are tested. Too broad stamps a handoff that never happened onto
# a session nobody replaced; too narrow leaves the historical rows as blank as
# they are today, with the ledger claiming success either way.
class StampReplacedSessionBackReferencesTest < ActiveSupport::TestCase
  setup do
    @entry = PostDeployTask::Registry.find("20260905181500")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
  end

  test "stamps a session replaced before Zimmer read the convention" do
    replaced = a_session
    replacement = a_replacement(replaced)
    # A handoff recorded before this code existed: the replacement carries the
    # convention, the replaced session carries nothing.
    strip_back_reference(replaced)

    run, outcome = run_task

    assert_nil outcome, "the sweep must finish rather than ask to be resumed"
    replaced.reload
    assert_equal replacement.id, replaced.custom_metadata[Session::REPLACED_BY_SESSION_KEY]
    assert_equal replacement.created_at.iso8601, replaced.custom_metadata[Session::REPLACED_AT_KEY],
      "the handoff is dated when it happened, not when the deploy ran"
    assert_includes replaced.custom_metadata[Session::REPLACED_BY_REASON_KEY],
      "infrastructure, not the task"
    assert_equal 1, run.stats["stamped"]
    assert replaced.logs.any? { |log| log.content.include?("was created to replace this one") },
      "the notice belongs on the replaced session's own timeline, where a human looks"
  end

  test "a second run stamps nothing" do
    replaced = a_session
    a_replacement(replaced)
    strip_back_reference(replaced)

    run_task
    run, = run_task

    assert_equal 0, run.stats["stamped"].to_i
    assert_equal 1, run.stats["already_stamped"].to_i
    notices = replaced.reload.logs.select { |log| log.content.include?("was created to replace this one") }
    assert_equal 1, notices.size, "a re-run must not re-log a handoff it already recorded"
  end

  test "leaves a session nobody replaced alone" do
    untouched = a_session

    run, = run_task

    assert_nil untouched.reload.custom_metadata[Session::REPLACED_BY_SESSION_KEY]
    assert_equal 0, run.stats["stamped"].to_i
  end

  test "counts a replacement whose replaces_session names nothing usable" do
    a_replacement(nil, replaces: "not-an-id")

    run, = run_task

    assert_equal 0, run.stats["stamped"].to_i
    assert_equal 1, run.stats["unresolvable"].to_i
  end

  test "counts a replacement naming a session that is gone" do
    a_replacement(nil, replaces: Session.maximum(:id).to_i + 10_000)

    run, = run_task

    assert_equal 1, run.stats["unresolvable"].to_i
  end

  test "the newest replacement is the one whose stamp survives" do
    replaced = a_session
    a_replacement(replaced)
    newer = a_replacement(replaced)
    strip_back_reference(replaced)

    run_task

    assert_equal newer.id, replaced.reload.custom_metadata[Session::REPLACED_BY_SESSION_KEY],
      "the sweep runs in id order, so the most recent replacement lands last"
  end

  private

  def run_task
    run = PostDeployTaskRun.ledger_for(@entry)
    assert run.claim!(owner: "test"), "the ledger row must be claimable"
    outcome = @task_class.new(run: run, logger: Rails.logger).up
    [ run.reload, outcome ]
  end

  def a_session(**attrs)
    Session.create!(
      prompt: "work #{SecureRandom.hex(4)}",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      **attrs
    )
  end

  # A replacement carrying the convention exactly as a router writes it.
  def a_replacement(replaced, replaces: nil)
    a_session(custom_metadata: {
      Session::REPLACES_SESSION_KEY => replaces || replaced.id,
      Session::REPLACES_REASON_KEY => "session #{replaced&.id} failed before its first turn with " \
                                      "Invalid cross-device link — infrastructure, not the task"
    })
  end

  # Undo the live stamp, so the row looks like one replaced before this shipped.
  def strip_back_reference(session)
    session.remove_custom_metadata!(
      Session::REPLACED_BY_SESSION_KEY,
      Session::REPLACED_AT_KEY,
      Session::REPLACED_BY_REASON_KEY
    )
    session.logs.destroy_all
    session.reload
  end
end
