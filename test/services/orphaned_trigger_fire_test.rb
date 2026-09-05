# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# A trigger fire is a one-shot event, and the session it creates is its only
# carrier. When that session reaches terminal `failed`, the fire is spent and
# nothing is left pointing at its subject — no message reaches a `failed`
# session, no wake reaches it, and the merge-gate contract reads it as
# unreachable.
#
# On 2026-08-23 trigger 352 fired correctly on a `ready to merge` label, created
# session 7844, and that session failed at first start 86 seconds later. The PR
# sat with no gate on it for eleven hours: the trigger's history showed the fire,
# the PR showed a clean label and no comment, and no alert fired anywhere (#632).
class OrphanedTriggerFireTest < ActiveSupport::TestCase
  setup do
    @trigger = triggers(:enabled_slack_trigger)
  end

  # A session shaped like 7844: created by a trigger, carrying the prompt the
  # fire built, dead before it did any of the work.
  def orphaned_session(metadata: {}, prompt: default_prompt, status: :failed)
    Session.create!(
      prompt: prompt,
      git_root: "https://github.com/tadasant/zimmer.git",
      genesis: SessionGenesis::GITHUB_LABEL,
      status: status,
      metadata: {
        "trigger_id" => @trigger.id,
        "trigger_name" => @trigger.name,
        "failure_reason" => "process_failed",
        "exit_status" => "Runtime session id 08654678-c2b5-4a40-a6b1-115bcf085b70 is already in use"
      }.merge(metadata)
    )
  end

  def default_prompt
    <<~PROMPT
      Rate this PR.

      ## GitHub pull request (label)

      - **URL:** https://github.com/tadasant/zimmer/pull/623
    PROMPT
  end

  # ── What the fix is: the drop announces itself ────────────────────────────

  test "alerts when a trigger-originated session fails, naming the trigger and the subject" do
    session = orphaned_session

    AlertService.expects(:raise_alert).with do |title, opts|
      assert_equal "Trigger session failed with its work undone", title
      assert_match(/trigger #{@trigger.id}/, opts[:details])
      assert_match(/CI Failure Handler/, opts[:details])
      assert_match(%r{https://github\.com/tadasant/zimmer/pull/623}, opts[:details])
      assert_match(%r{/sessions/#{session.id}}, opts[:details])
      assert_match(%r{/triggers/#{@trigger.id}}, opts[:details])
      assert_equal "OrphanedTriggerFire", opts[:source]
      true
    end.returns(true)

    assert OrphanedTriggerFire.report!(session)
  end

  test "says why the session died, so the reader knows whether to re-dispatch or investigate" do
    session = orphaned_session

    AlertService.expects(:raise_alert).with do |_title, opts|
      assert_match(/already in use/, opts[:details])
      true
    end.returns(true)

    OrphanedTriggerFire.report!(session)
  end

  test "records the drop on the session's own timeline, not only in Slack" do
    session = orphaned_session
    AlertService.stubs(:raise_alert).returns(true)

    assert_difference -> { session.logs.count }, 1 do
      OrphanedTriggerFire.report!(session)
    end

    entry = session.logs.order(:created_at).last
    assert_equal "error", entry.level
    assert_match(/failed before handing its work back/, entry.content)
    assert_match(%r{https://github\.com/tadasant/zimmer/pull/623}, entry.content)
  end

  test "stamps the session so the drop is visible on the row itself" do
    session = orphaned_session
    AlertService.stubs(:raise_alert).returns(true)

    OrphanedTriggerFire.report!(session)

    assert session.reload.metadata[OrphanedTriggerFire::REPORTED_AT_KEY].present?
  end

  # ── What must not become noisy ────────────────────────────────────────────

  test "an ordinary session failure with no trigger behind it is not reported" do
    session = Session.create!(
      prompt: "Do a thing a human asked for",
      git_root: "https://github.com/tadasant/zimmer.git",
      genesis: SessionGenesis::WEB_UI,
      status: :failed,
      metadata: { "failure_reason" => "process_failed" }
    )

    AlertService.expects(:raise_alert).never

    refute OrphanedTriggerFire.candidate?(session)
    refute OrphanedTriggerFire.report!(session)
    assert_equal 0, session.logs.count
  end

  test "a trigger-originated session that has not failed is not reported" do
    session = orphaned_session(status: :running)

    AlertService.expects(:raise_alert).never

    refute OrphanedTriggerFire.candidate?(session)
    refute OrphanedTriggerFire.report!(session)
  end

  test "reports once per session, so a retried job cannot double-page" do
    session = orphaned_session
    AlertService.expects(:raise_alert).once.returns(true)

    assert OrphanedTriggerFire.report!(session)
    refute OrphanedTriggerFire.report!(session)
    assert_equal 1, session.logs.count
  end

  # The stamp goes down BEFORE the network round trip: a job retried over a
  # half-finished report must not send the same drop twice.
  test "a Slack post that blows up does not leave the session open to a second report" do
    session = orphaned_session
    AlertService.expects(:raise_alert).once.raises(StandardError, "slack is down")

    refute OrphanedTriggerFire.report!(session)
    assert session.reload.metadata[OrphanedTriggerFire::REPORTED_AT_KEY].present?
  end

  # A session genuinely restarted and failed again is a new drop, not the same
  # one — the stamp rides on the shared stale-metadata list that every restart
  # and follow-up clears.
  test "the stamp is cleared by a restart, so a second genuine failure reports again" do
    assert_includes Session::STALE_RETRY_METADATA_KEYS, OrphanedTriggerFire::REPORTED_AT_KEY
  end

  test "never raises, whatever the session is carrying" do
    assert_nothing_raised do
      refute OrphanedTriggerFire.report!(nil)
    end
  end

  # ── Degrading gracefully ──────────────────────────────────────────────────

  test "reports a fire whose trigger has since been deleted" do
    session = orphaned_session(metadata: { "trigger_id" => 999_999 })

    AlertService.expects(:raise_alert).with do |_title, opts|
      assert_match(/trigger 999999/, opts[:details])
      # The name is still readable off the session, which is the whole reason the
      # fire stamps it there — but there is no trigger row left to link.
      assert_match(/CI Failure Handler/, opts[:details])
      assert_match(%r{/sessions/#{session.id}}, opts[:details])
      refute_match(%r{/triggers/}, opts[:details])
      true
    end.returns(true)

    assert OrphanedTriggerFire.report!(session)
  end

  test "reports a fire with no GitHub subject in its prompt" do
    session = orphaned_session(prompt: "The nightly backlog groom is due.")

    AlertService.expects(:raise_alert).with do |_title, opts|
      assert_match(/session #{session.id}/, opts[:details])
      true
    end.returns(true)

    assert OrphanedTriggerFire.report!(session)
  end

  # Each orphaned fire is a distinct work item somebody has to re-dispatch, so
  # two of them must not collapse into one message the way an unclassified
  # failure mode does.
  test "two orphaned fires on the same trigger get distinct dedup keys" do
    first = orphaned_session
    second = orphaned_session

    keys = []
    AlertService.stubs(:raise_alert).with do |_title, opts|
      keys << opts[:dedup_key]
      true
    end.returns(true)

    OrphanedTriggerFire.report!(first)
    OrphanedTriggerFire.report!(second)

    assert_equal 2, keys.uniq.size, "collapsing two drops would leave one subject still orphaned"
  end
end
