# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class QueueRecoveryModeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    AppSetting.delete_all
    GoodJob::Setting.delete_all
    # Every entry/exit raises a Slack alert. The alert path is asserted
    # explicitly in its own tests; everywhere else it is noise, and the test
    # environment is outside ALERTING_ENVIRONMENTS anyway.
    AlertService.stubs(:raise_alert).returns(true)
  end

  teardown do
    GoodJob::Setting.delete_all
  end

  # --- The invariant the whole feature rests on --------------------------------

  test "halts the demand-side queues and deliberately leaves agents running" do
    QueueRecoveryMode.enter!(reason: "trigger stampede")

    paused = GoodJob.paused(:queues)
    assert_equal %w[default inference maintenance pollers triggers], paused.sort
    refute_includes paused, "agents",
      "agents must keep running or recovery mode halts the investigation it exists to enable"
  end

  test "the live queues are not in the halted set" do
    assert_empty QueueRecoveryMode::HALTED_QUEUES & QueueRecoveryMode::LIVE_QUEUES
    assert_includes QueueRecoveryMode::LIVE_QUEUES, "agents"
    assert_includes QueueRecoveryMode::LIVE_QUEUES, "auth"
  end

  # A queue in neither list is neither halted nor deliberately spared — it just
  # escapes recovery mode because nobody remembered it. The `auth` lane did exactly
  # that when it was added, so assert coverage rather than only disjointness.
  test "every configured queue is either halted or explicitly live" do
    configured = ConnectionBudget.good_job_queue_threads.keys.map(&:to_s)
    classified = QueueRecoveryMode::HALTED_QUEUES | QueueRecoveryMode::LIVE_QUEUES

    assert_empty configured - classified,
      "queue(s) in neither HALTED_QUEUES nor LIVE_QUEUES: #{(configured - classified).inspect}"
  end

  test "config.good_job.enable_pauses is on, or every pause is a silent no-op" do
    assert GoodJob.configuration.enable_pauses
  end

  # The one test that proves the halt reaches the mechanism that actually decides
  # what runs. `exclude_paused` is the scope GoodJob applies in its dequeue query
  # (GoodJob::Job.queue_parser / .dequeueing_ordered), so a row that survives it is
  # a row a scheduler thread can pick up.
  test "an enqueued job on a halted queue drops out of GoodJob's dequeue scope, and an agents job does not" do
    halted = GoodJob::Job.create!(queue_name: "pollers", job_class: "FakePollerJob", scheduled_at: Time.current)
    live = GoodJob::Job.create!(queue_name: "agents", job_class: "FakeAgentJob", scheduled_at: Time.current)

    assert_includes GoodJob::Job.exclude_paused.pluck(:id), halted.id
    assert_includes GoodJob::Job.exclude_paused.pluck(:id), live.id

    QueueRecoveryMode.enter!

    dequeueable = GoodJob::Job.exclude_paused.pluck(:id)
    refute_includes dequeueable, halted.id
    assert_includes dequeueable, live.id,
      "an agent session must still be dequeueable, or recovery mode halts its own investigation"

    QueueRecoveryMode.exit!

    assert_includes GoodJob::Job.exclude_paused.pluck(:id), halted.id,
      "jobs are frozen while halted, not discarded"
  end

  # --- Enter -------------------------------------------------------------------

  test "enter records who, why and when it auto-exits" do
    freeze_time do
      status = QueueRecoveryMode.enter!(reason: "916 jobs/hour", ttl: 30.minutes, actor: "web UI")

      assert status.active?
      assert_equal "916 jobs/hour", status.reason
      assert_equal "web UI", status.entered_by
      assert_equal Time.current, status.entered_at
      assert_equal Time.current + 30.minutes, status.expires_at
      assert_equal 30 * 60, status.expires_in
    end
  end

  test "enter defaults the ttl and clamps out-of-range values" do
    freeze_time do
      assert_equal Time.current + QueueRecoveryMode::DEFAULT_TTL, QueueRecoveryMode.enter!.expires_at

      QueueRecoveryMode.exit!
      assert_equal Time.current + QueueRecoveryMode::MAX_TTL,
        QueueRecoveryMode.enter!(ttl: 99.hours).expires_at

      QueueRecoveryMode.exit!
      assert_equal Time.current + QueueRecoveryMode::MIN_TTL,
        QueueRecoveryMode.enter!(ttl: 1.second).expires_at
    end
  end

  test "re-entering extends the window but keeps the original entry time" do
    entered_at = nil

    travel_to Time.utc(2026, 8, 3, 12, 0, 0) do
      entered_at = QueueRecoveryMode.enter!(ttl: 30.minutes).entered_at
    end

    travel_to Time.utc(2026, 8, 3, 12, 20, 0) do
      status = QueueRecoveryMode.enter!(ttl: 30.minutes, reason: "still digging")

      assert_equal entered_at, status.entered_at, "the incident started when it started"
      assert_equal Time.utc(2026, 8, 3, 12, 50, 0), status.expires_at
      assert_equal "still digging", status.reason
    end
  end

  test "extending without a reason keeps the reason and actor already on record" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) do
      QueueRecoveryMode.enter!(reason: "trigger stampede", actor: "web UI", ttl: 30.minutes)
    end

    travel_to Time.utc(2026, 8, 3, 12, 20, 0) do
      status = QueueRecoveryMode.enter!(ttl: 30.minutes)

      assert_equal "trigger stampede", status.reason, "an incident does not stop having a cause"
      assert_equal "web UI", status.entered_by
    end
  end

  test "an extension pages rather than colliding with the original entry alert" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) do
      QueueRecoveryMode.enter!(reason: "trigger stampede", ttl: 30.minutes)
    end

    alerts = capture_alerts do
      travel_to(Time.utc(2026, 8, 3, 12, 20, 0)) { QueueRecoveryMode.enter!(ttl: 30.minutes) }
    end

    assert_equal 1, alerts.size
    assert_equal "Queue recovery mode extended", alerts.first[:title]
    # entered_at is deliberately preserved across an extension, so the expiry has to
    # be in the dedup key or AlertService swallows every extension for an hour.
    refute_equal(
      "queue_recovery_mode_entered:2026-08-03T12:00:00Z",
      alerts.first[:dedup_key]
    )
  end

  test "enter refuses when GoodJob pauses are disabled, rather than faking a halt" do
    GoodJob.configuration.stubs(:enable_pauses).returns(false)

    assert_raises(QueueRecoveryMode::NotAvailable) { QueueRecoveryMode.enter! }
    assert_empty GoodJob.paused(:queues)
    refute QueueRecoveryMode.active?
  end

  # --- Exit --------------------------------------------------------------------

  test "exit unpauses every halted queue and clears the metadata" do
    QueueRecoveryMode.enter!(reason: "x")
    status = QueueRecoveryMode.exit!(actor: "web UI")

    refute status.active?
    assert_nil status.entered_at
    assert_empty GoodJob.paused(:queues)
    refute QueueRecoveryMode.active?
  end

  test "exit is idempotent when the mode was never entered" do
    assert_nothing_raised { QueueRecoveryMode.exit! }
    refute QueueRecoveryMode.active?
  end

  test "exit still unpauses when GoodJob pauses have since been disabled" do
    QueueRecoveryMode.enter!
    GoodJob.configuration.stubs(:enable_pauses).returns(false)

    QueueRecoveryMode.exit!

    assert_empty GoodJob.paused(:queues)
  end

  # The one failure here that no timer resolves. Clearing the metadata would leave
  # the queue paused with nothing left that would ever lift it.
  test "a failed unpause keeps the metadata so the backstop retries, and pages" do
    QueueRecoveryMode.enter!(reason: "x")
    GoodJob.stubs(:unpause).with(queue: "pollers").raises(ActiveRecord::StatementInvalid, "boom")
    GoodJob.stubs(:unpause).with(queue: "triggers").returns(true)
    GoodJob.stubs(:unpause).with(queue: "inference").returns(true)
    GoodJob.stubs(:unpause).with(queue: "maintenance").returns(true)
    GoodJob.stubs(:unpause).with(queue: "default").returns(true)

    alerts = capture_alerts { QueueRecoveryMode.exit! }

    assert QueueRecoveryMode.active?, "the mode must stay on record while a queue is still halted"
    assert_includes GoodJob.paused(:queues), "pollers"
    assert_equal 1, alerts.size
    assert_includes alerts.first[:title], "could NOT resume pollers"
  end

  test "expire_if_due! reports false when a queue could not be unpaused" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) do
      QueueRecoveryMode.enter!(ttl: 10.minutes)
    end
    GoodJob.stubs(:unpause).raises(ActiveRecord::StatementInvalid, "boom")

    travel_to Time.utc(2026, 8, 3, 12, 11, 0) do
      refute QueueRecoveryMode.expire_if_due!,
        "a backstop that did not actually resume must not claim it did"
    end
  end

  test "exit survives a queue that was already unpaused by hand" do
    QueueRecoveryMode.enter!
    GoodJob.unpause(queue: "pollers")

    assert_nothing_raised { QueueRecoveryMode.exit! }
    assert_empty GoodJob.paused(:queues)
  end

  # --- The TTL backstop --------------------------------------------------------

  test "status reports inactive past the expiry even before anything reconciles" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) do
      QueueRecoveryMode.enter!(ttl: 10.minutes)
    end

    travel_to Time.utc(2026, 8, 3, 12, 11, 0) do
      refute QueueRecoveryMode.active?,
        "no surface may report a halt for a window that has already elapsed"
    end
  end

  test "expire_if_due! resumes processing once the window elapses" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) do
      QueueRecoveryMode.enter!(ttl: 10.minutes)
    end

    travel_to Time.utc(2026, 8, 3, 12, 11, 0) do
      assert QueueRecoveryMode.expire_if_due!
      assert_empty GoodJob.paused(:queues)
    end
  end

  test "expire_if_due! leaves an unexpired window alone" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) do
      QueueRecoveryMode.enter!(ttl: 60.minutes)
    end

    travel_to Time.utc(2026, 8, 3, 12, 30, 0) do
      refute QueueRecoveryMode.expire_if_due!
      assert QueueRecoveryMode.active?
      assert_equal 5, GoodJob.paused(:queues).size
    end
  end

  test "expire_if_due! is a no-op when the mode was never entered" do
    refute QueueRecoveryMode.expire_if_due!
  end

  test "expire_if_due! swallows failures rather than breaking its callers" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) do
      QueueRecoveryMode.enter!(ttl: 10.minutes)
    end
    QueueRecoveryMode.stubs(:exit!).raises(ActiveRecord::StatementInvalid, "boom")

    travel_to Time.utc(2026, 8, 3, 12, 11, 0) do
      refute QueueRecoveryMode.expire_if_due!
    end
  end

  # --- Alerts ------------------------------------------------------------------

  # Records what AlertService was called with, tolerant of how Mocha hands a
  # keyword-argument call to a `with` block.
  def capture_alerts
    captured = []
    AlertService.stubs(:raise_alert).with { |*args| captured << args; true }.returns(true)
    yield
    captured.map do |args|
      kwargs = args.last.is_a?(Hash) ? args.last : {}
      { title: args.first }.merge(kwargs.symbolize_keys)
    end
  end

  test "entering pages the alert channel and names what is and is not halted" do
    alerts = capture_alerts { QueueRecoveryMode.enter!(reason: "trigger stampede", actor: "web UI") }

    assert_equal 1, alerts.size
    assert_equal "Queue recovery mode ENTERED", alerts.first[:title]
    assert_includes alerts.first[:details], "pollers"
    assert_includes alerts.first[:details], "agents"
    assert_includes alerts.first[:details], "trigger stampede"
  end

  test "an auto-exit says it was the TTL and not a human" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) do
      QueueRecoveryMode.enter!(ttl: 10.minutes)
    end

    alerts = capture_alerts do
      travel_to(Time.utc(2026, 8, 3, 12, 11, 0)) { QueueRecoveryMode.expire_if_due! }
    end

    assert_equal 1, alerts.size
    assert_equal "Queue recovery mode auto-exited (TTL)", alerts.first[:title]
    assert_includes alerts.first[:details], "TTL backstop"
  end

  test "the deferred alert path hands the Slack post to a job" do
    QueueRecoveryMode.enter!(reason: "x")
    AlertService.unstub(:raise_alert)
    AlertService.stubs(:raise_alert).returns(true)

    assert_enqueued_with(job: QueueRecoveryModeAlertJob) do
      QueueRecoveryMode.exit!(defer_alert: true)
    end
  end

  test "exiting a mode that was never on does not page" do
    AlertService.unstub(:raise_alert)
    AlertService.expects(:raise_alert).never

    QueueRecoveryMode.exit!
  end

  # --- Status shape ------------------------------------------------------------

  test "status serializes for the API and MCP surfaces" do
    freeze_time do
      QueueRecoveryMode.enter!(reason: "why", ttl: 45.minutes, actor: "REST API")
      json = QueueRecoveryMode.status.as_json.with_indifferent_access

      assert json[:active]
      assert_equal "why", json[:reason]
      assert_equal "REST API", json[:entered_by]
      assert_equal QueueRecoveryMode::HALTED_QUEUES, json[:halted_queues]
      assert_equal QueueRecoveryMode::LIVE_QUEUES, json[:live_queues]
      assert_equal 45 * 60, json[:expires_in_seconds]
      assert_equal Time.current.iso8601, json[:entered_at]
    end
  end

  test "status is inactive and safe when nothing has ever been stored" do
    status = QueueRecoveryMode.status

    refute status.active?
    assert_nil status.entered_at
    assert_nil status.expires_in
    assert_empty QueueRecoveryMode.paused_queues
  end

  test "a queue an operator paused by hand shows in paused_queues without claiming the mode is on" do
    GoodJob.pause(queue: "pollers")

    refute QueueRecoveryMode.status.active?, "Zimmer did not enter the mode, so it must not claim it did"
    assert_includes QueueRecoveryMode.paused_queues, "pollers",
      "but the truth about the queue must still show"
    assert_includes QueueRecoveryMode.status.as_json[:paused_queues], "pollers"
  end

  # The banner is rendered on every page, so building a Status must not cost a
  # `good_job_settings` read on top of the settings read it already does.
  test "status does not query GoodJob's pauses" do
    QueueRecoveryMode.expects(:paused_queues).never

    QueueRecoveryMode.status
  end

  test "an unreadable settings row degrades to no recovery mode, but not on an aborted transaction" do
    # The degrade is right when the read failed on its own. It is wrong on a
    # transaction Postgres has already aborted — AppSetting.current re-raises
    # there, and swallowing it back into `{}` would put #924 back one level up.
    AppSetting.stubs(:current).raises(ActiveRecord::StatementInvalid, "relation does not exist")

    assert_nothing_raised { refute QueueRecoveryMode.active? }

    AppSetting.unstub(:current)

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true) do
        begin
          ActiveRecord::Base.connection.execute("SELECT no_such_column_anywhere")
        rescue ActiveRecord::StatementInvalid
          # The transaction is aborted now, exactly as it was in production.
        end

        QueueRecoveryMode.active?
      end
    end

    assert_kind_of PG::InFailedSqlTransaction, error.cause
  end
end
