# frozen_string_literal: true

require "test_helper"

class TestflightFeedbackPollerTest < ActiveSupport::TestCase
  include AppStoreConnectFixtures

  APP = AppStoreConnectFixtures::APP_ID
  CRASHES = "/v1/apps/#{APP}/betaFeedbackCrashSubmissions".freeze
  SCREENSHOTS = "/v1/apps/#{APP}/betaFeedbackScreenshotSubmissions".freeze

  setup do
    @exporter = RecordingExporter.new
  end

  def routes(crashes:, screenshots: page([]), logs: {})
    {
      "/v1/apps" => apps,
      CRASHES => page(crashes),
      SCREENSHOTS => screenshots
    }.merge(logs.transform_keys { |id| "/v1/betaFeedbackCrashSubmissions/#{id}/crashLog" })
  end

  def run_poller(client)
    TestflightFeedbackPoller.new(client: client, exporter: @exporter).run
  end

  test "stores crash submissions with their full crash logs, and screenshot submissions" do
    client = FakeClient.new(routes(
      crashes: [ submission("crash-1", type: "betaFeedbackCrashSubmissions", created: "2026-10-28T21:14:03Z", comment: "died when CarPlay connected") ],
      screenshots: page([ submission("shot-1", type: "betaFeedbackScreenshotSubmissions", created: "2026-10-28T20:00:00Z",
        comment: "button off screen", screenshots: [ { "url" => "https://example.test/s.png", "width" => 1179, "height" => 2556 } ]) ]),
      logs: { "crash-1" => crash_log }
    ))

    result = run_poller(client)

    assert_equal 2, result.created
    assert_equal 1, result.crash_logs_fetched
    crash = TestflightFeedback.find_by!(asc_id: "crash-1")
    assert_equal "crash", crash.kind
    assert_equal "212", crash.build_number
    assert_equal "iPhone16,2", crash.device_model
    assert_equal "died when CarPlay connected", crash.comment
    assert_equal AppStoreConnectFixtures::CRASH_LOG, crash.crash_log
    assert_equal Time.utc(2026, 10, 28, 21, 14, 3), crash.submitted_at
    assert_match(/EXC_CRASH \(SIGABRT\)/, crash.headline)
    assert_equal 81, crash.raw_attributes["batteryPercentage"]

    shot = TestflightFeedback.find_by!(asc_id: "shot-1")
    assert_equal "screenshot", shot.kind
    assert_nil shot.crash_log
    assert_equal 1179, shot.raw_attributes["screenshots"].first["width"]

    list_params = client.calls.find { |path, _| path == CRASHES }.last
    assert_equal "-createdDate", list_params["sort"]
    assert_equal "build", list_params["include"]
    assert_equal "200", list_params["limit"]
  end

  test "a second pass over the same submissions stores nothing and fetches no crash log again" do
    client = FakeClient.new(routes(
      crashes: [ submission("crash-1", type: "betaFeedbackCrashSubmissions", created: "2026-10-28T21:14:03Z") ],
      logs: { "crash-1" => crash_log }
    ))
    run_poller(client)

    again = FakeClient.new(routes(crashes: [ submission("crash-1", type: "betaFeedbackCrashSubmissions", created: "2026-10-28T21:14:03Z") ]))
    result = assert_no_difference -> { TestflightFeedback.count } do
      run_poller(again)
    end

    assert_equal 0, result.created
    assert_equal 0, result.crash_logs_fetched
    refute again.paths.any? { |path| path.end_with?("/crashLog") }, "a stored crash log is never re-fetched"
    assert_equal 1, @exporter.records.size, "a crash goes on the log stream once"
  end

  test "walks every page, so a pass that failed halfway leaves nothing behind for good" do
    next_page = "https://api.appstoreconnect.apple.com/v1/apps/#{APP}/betaFeedbackCrashSubmissions?cursor=2"
    newest = submission("crash-new", type: "betaFeedbackCrashSubmissions", created: "2026-10-28T00:00:00Z")
    older = submission("crash-old", type: "betaFeedbackCrashSubmissions", created: "2026-10-01T00:00:00Z")
    logs = {
      "/v1/betaFeedbackCrashSubmissions/crash-new/crashLog" => crash_log,
      "/v1/betaFeedbackCrashSubmissions/crash-old/crashLog" => crash_log
    }
    failing = FakeClient.new({ "/v1/apps" => apps, CRASHES => page([ newest ], next_url: next_page),
      next_page => AppStoreConnect::Client::Error.new("App Store Connect answered 503", status: 503), SCREENSHOTS => page([]) }.merge(logs))

    assert_raises(AppStoreConnect::Client::Error) { run_poller(failing) }
    assert_equal [ "crash-new" ], TestflightFeedback.pluck(:asc_id)

    healthy = FakeClient.new({ "/v1/apps" => apps, CRASHES => page([ newest ], next_url: next_page),
      next_page => page([ older ]), SCREENSHOTS => page([]) }.merge(logs))
    result = run_poller(healthy)

    assert_equal 1, result.created, "page 1 held nothing new, and the pass read page 2 anyway"
    assert_equal %w[crash-new crash-old], TestflightFeedback.order(:asc_id).pluck(:asc_id)
  end

  test "one crash log App Store Connect refuses does not stop the others being fetched" do
    client = FakeClient.new(routes(
      crashes: [ submission("crash-1", type: "betaFeedbackCrashSubmissions", created: "2026-10-28T21:14:03Z"),
                 submission("crash-2", type: "betaFeedbackCrashSubmissions", created: "2026-10-28T20:00:00Z") ],
      logs: { "crash-1" => AppStoreConnect::Client::Error.new("App Store Connect answered 500", status: 500), "crash-2" => crash_log }
    ))

    result = run_poller(client)

    assert_equal 1, result.crash_logs_fetched
    assert_equal 1, result.crash_logs_pending
    assert_nil TestflightFeedback.find_by!(asc_id: "crash-1").crash_log
    refute_nil TestflightFeedback.find_by!(asc_id: "crash-2").crash_log
  end

  test "a key App Store Connect refuses fails the pass rather than reading as a pending log" do
    client = FakeClient.new(routes(
      crashes: [ submission("crash-1", type: "betaFeedbackCrashSubmissions", created: "2026-10-28T21:14:03Z") ],
      logs: { "crash-1" => AppStoreConnect::Client::Error.new("App Store Connect answered 403", status: 403) }
    ))

    assert_raises(AppStoreConnect::Client::Error) { run_poller(client) }
  end

  test "a 200 with no logText reads as pending" do
    client = FakeClient.new(routes(
      crashes: [ submission("crash-1", type: "betaFeedbackCrashSubmissions", created: "2026-10-28T21:14:03Z") ],
      logs: { "crash-1" => { "data" => nil } }
    ))

    assert_equal 1, run_poller(client).crash_logs_pending
  end

  test "fetches at most CRASH_LOGS_PER_PASS crash logs a pass, newest submissions first" do
    (TestflightFeedbackPoller::CRASH_LOGS_PER_PASS + 2).times do |i|
      TestflightFeedback.create!(asc_id: "c#{i}", kind: "crash", submitted_at: i.minutes.ago)
    end
    logs = (0...(TestflightFeedbackPoller::CRASH_LOGS_PER_PASS + 2)).to_h { |i| [ "c#{i}", crash_log ] }
    client = FakeClient.new(routes(crashes: [], logs: logs))

    result = run_poller(client)

    assert_equal TestflightFeedbackPoller::CRASH_LOGS_PER_PASS, result.crash_logs_fetched
    assert_equal %w[c25 c26], TestflightFeedback.where(crash_log: nil).order(:asc_id).pluck(:asc_id)
  end

  test "a crash log App Store Connect has not produced yet is left pending and fetched on a later pass" do
    crash = submission("crash-1", type: "betaFeedbackCrashSubmissions", created: "2026-10-28T21:14:03Z")
    first = FakeClient.new(routes(crashes: [ crash ], logs: { "crash-1" => AppStoreConnect::Client::NotFound.new("not yet", status: 404) }))

    result = run_poller(first)

    assert_equal 1, result.created
    assert_equal 1, result.crash_logs_pending
    assert_nil TestflightFeedback.find_by!(asc_id: "crash-1").crash_log
    assert_empty @exporter.records

    second = FakeClient.new(routes(crashes: [ crash ], logs: { "crash-1" => crash_log }))
    result = run_poller(second)

    assert_equal 0, result.created
    assert_equal 1, result.crash_logs_fetched
    assert_equal AppStoreConnectFixtures::CRASH_LOG, TestflightFeedback.find_by!(asc_id: "crash-1").crash_log
  end

  test "stops asking for a crash log once the submission is older than the retry window" do
    TestflightFeedback.create!(asc_id: "crash-stale", kind: "crash", created_at: 8.days.ago)
    TestflightFeedback.create!(asc_id: "crash-backfilled", kind: "crash", submitted_at: 30.days.ago)
    client = FakeClient.new(routes(crashes: []))

    run_poller(client)

    refute client.paths.any? { |path| path.end_with?("/crashLog") }
  end

  test "ships one ios.crash record per new crash: a pointer and a headline, never the log or the comment" do
    client = FakeClient.new(routes(
      crashes: [ submission("crash-1", type: "betaFeedbackCrashSubmissions", created: "2026-10-28T21:14:03Z", comment: "private words") ],
      logs: { "crash-1" => crash_log }
    ))

    run_poller(client)

    record = @exporter.records.sole
    assert_equal "ios.crash", record[:scope]
    assert_equal "WARN", record[:severity]
    assert_match(/get_testflight_crashes id=crash-1/, record[:body])
    assert_match(/EXC_CRASH/, record[:body])
    refute_match(/private words|pthread_kill/, record.to_s)
    assert_equal AppStoreConnectFixtures::CRASH_LOG.length, record[:attributes]["crash_log_chars"]
  end

  test "an app the key cannot see is an error, not an empty pass" do
    client = FakeClient.new("/v1/apps" => { "data" => [] })

    error = assert_raises(AppStoreConnect::Client::Error) { run_poller(client) }
    assert_match(/com\.tadasant\.zimmer/, error.message)
  end
end
