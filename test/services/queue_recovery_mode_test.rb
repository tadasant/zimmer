# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class QueueRecoveryModeTest < ActiveSupport::TestCase
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
    assert_equal %w[default pollers triggers], paused.sort
    refute_includes paused, "agents",
      "agents must keep running or recovery mode halts the investigation it exists to enable"
  end

  test "the live queue is not in the halted set" do
    assert_empty QueueRecoveryMode::HALTED_QUEUES & QueueRecoveryMode::LIVE_QUEUES
    assert_includes QueueRecoveryMode::LIVE_QUEUES, "agents"
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

  test "enter refuses when GoodJob pauses are disabled, rather than faking a halt" do
    QueueRecoveryMode.stubs(:enabled?).returns(false)

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
    QueueRecoveryMode.stubs(:enabled?).returns(false)

    QueueRecoveryMode.exit!

    assert_empty GoodJob.paused(:queues)
  end

  test "exit survives a queue that was already unpaused by hand" do
    QueueRecoveryMode.enter!
    GoodJob.unpause(queue: "pollers")

    assert_nothing_raised { QueueRecoveryMode.exit! }
    assert_empty GoodJob.paused(:queues)
  end

  # --- The TTL backstop --------------------------------------------------------

  test "status reports inactive past the expiry even before anything reconciles" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) { QueueRecoveryMode.enter!(ttl: 10.minutes) }

    travel_to Time.utc(2026, 8, 3, 12, 11, 0) do
      refute QueueRecoveryMode.active?,
        "no surface may report a halt for a window that has already elapsed"
    end
  end

  test "expire_if_due! resumes processing once the window elapses" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) { QueueRecoveryMode.enter!(ttl: 10.minutes) }

    travel_to Time.utc(2026, 8, 3, 12, 11, 0) do
      assert QueueRecoveryMode.expire_if_due!
      assert_empty GoodJob.paused(:queues)
    end
  end

  test "expire_if_due! leaves an unexpired window alone" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) { QueueRecoveryMode.enter!(ttl: 60.minutes) }

    travel_to Time.utc(2026, 8, 3, 12, 30, 0) do
      refute QueueRecoveryMode.expire_if_due!
      assert QueueRecoveryMode.active?
      assert_equal 3, GoodJob.paused(:queues).size
    end
  end

  test "expire_if_due! is a no-op when the mode was never entered" do
    refute QueueRecoveryMode.expire_if_due!
  end

  test "expire_if_due! swallows failures rather than breaking its callers" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) { QueueRecoveryMode.enter!(ttl: 10.minutes) }
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
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) { QueueRecoveryMode.enter!(ttl: 10.minutes) }

    alerts = capture_alerts do
      travel_to(Time.utc(2026, 8, 3, 12, 11, 0)) { QueueRecoveryMode.expire_if_due! }
    end

    assert_equal 1, alerts.size
    assert_equal "Queue recovery mode auto-exited (TTL)", alerts.first[:title]
    assert_includes alerts.first[:details], "TTL backstop"
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
    assert_empty status.paused_queues
  end

  test "status reports a queue an operator paused by hand in the GoodJob dashboard" do
    GoodJob.pause(queue: "pollers")

    status = QueueRecoveryMode.status

    refute status.active?, "Zimmer did not enter the mode, so it must not claim it did"
    assert_includes status.paused_queues, "pollers", "but the truth about the queue must still show"
  end
end
