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
  def orphaned_session(metadata: {}, prompt: default_prompt, status: :failed,
                       genesis: SessionGenesis::GITHUB_LABEL)
    Session.create!(
      prompt: prompt,
      git_root: "https://github.com/tadasant/zimmer.git",
      genesis: genesis,
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
    assert_match(/The fire that created it is spent/, entry.content)
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

  # The stamp goes down AFTER the report. Stamping first would turn a Slack
  # outage into a permanent silent drop — the exact bug this service removes,
  # reintroduced inside the fix.
  test "a Slack post that blows up leaves the session eligible to report again" do
    session = orphaned_session
    AlertService.expects(:raise_alert).once.raises(StandardError, "slack is down")

    refute OrphanedTriggerFire.report!(session)
    assert_nil session.reload.metadata[OrphanedTriggerFire::REPORTED_AT_KEY]

    AlertService.expects(:raise_alert).once.returns(true)
    assert OrphanedTriggerFire.report!(session)
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

  # ── The population: only a fire that is genuinely consumed ────────────────

  # A recurring schedule re-fires on its next interval, so "no retry is coming"
  # would be a false statement about it.
  test "a scheduled trigger's session is not reported — its next tick is the retry" do
    session = orphaned_session(genesis: SessionGenesis::SCHEDULE)

    AlertService.expects(:raise_alert).never

    refute OrphanedTriggerFire.candidate?(session)
    refute OrphanedTriggerFire.report!(session)
  end

  test "a system_event trigger's session is not reported — an unhandled event is re-armed" do
    session = orphaned_session(genesis: SessionGenesis::SYSTEM_EVENT)

    AlertService.expects(:raise_alert).never

    refute OrphanedTriggerFire.candidate?(session)
  end

  # Triggers::ManualFire stamps web_ui (Invoke) or api (REST / MCP). Somebody
  # pressed a button and is watching the session they just made.
  test "a hand-fired trigger's session is not reported" do
    [ SessionGenesis::WEB_UI, SessionGenesis::API ].each do |genesis|
      refute OrphanedTriggerFire.candidate?(orphaned_session(genesis: genesis)),
        "#{genesis} is a manual invoke, not a consumed event"
    end
  end

  # A burst-notice session exists to say the trigger is bursting. It is not the
  # work item, so its failure drops nothing.
  test "a burst-notice session is not reported" do
    session = orphaned_session(metadata: { "burst_notice" => true })

    AlertService.expects(:raise_alert).never

    refute OrphanedTriggerFire.candidate?(session)
  end

  test "every consumed-event genesis is reported" do
    OrphanedTriggerFire::CONSUMED_EVENT_GENESES.each do |genesis|
      assert OrphanedTriggerFire.candidate?(orphaned_session(genesis: genesis)),
        "#{genesis} consumes its event and must be reported"
    end
  end

  # ── Rendering the failure ─────────────────────────────────────────────────

  # AlertService clamps the details block, and the links are rendered last, so an
  # unbounded exit_status would push the reader's way back to the session off the
  # end of the message whose only job is to get them there.
  test "a huge exit_status is bounded so the links survive" do
    session = orphaned_session(metadata: { "exit_status" => "boom " * 5_000 })

    AlertService.expects(:raise_alert).with do |_title, opts|
      assert_operator opts[:details].length, :<, AlertService::DETAILS_SECTION_MAX_CHARS
      assert_match(%r{/sessions/#{session.id}}, opts[:details])
      assert_match(%r{/triggers/#{@trigger.id}}, opts[:details])
      true
    end.returns(true)

    assert OrphanedTriggerFire.report!(session)
  end

  # A session that died on an exception records no exit_status at all, and the
  # classified summary alone renders as the bare word "Exception".
  test "an exception death reports its exception message" do
    session = orphaned_session(metadata: {
      "failure_reason" => "exception",
      "exit_status" => nil,
      "exception_message" => "PG::ConnectionBad: could not connect to server"
    })

    AlertService.expects(:raise_alert).with do |_title, opts|
      assert_match(/could not connect to server/, opts[:details])
      true
    end.returns(true)

    assert OrphanedTriggerFire.report!(session)
  end

  # GithubTriggerPollerJob appends its own context block AFTER the operator's
  # interpolated template, and that template can carry the issue or PR body —
  # which anyone who can file an issue writes.
  test "the subject comes from the poller's own context block, not from body text" do
    session = orphaned_session(prompt: <<~PROMPT)
      Rate this. The reporter wrote: see https://github.com/attacker/repo/pull/1

      ## GitHub pull request (label)

      - **URL:** https://github.com/tadasant/zimmer/pull/623
    PROMPT

    AlertService.expects(:raise_alert).with do |_title, opts|
      assert_match(%r{\*Subject:\* https://github\.com/tadasant/zimmer/pull/623}, opts[:details])
      refute_match(%r{attacker/repo}, opts[:details])
      true
    end.returns(true)

    assert OrphanedTriggerFire.report!(session)
  end
end
