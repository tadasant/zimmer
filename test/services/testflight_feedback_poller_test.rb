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

  test "stops paging at the first page with nothing new" do
    old = submission("crash-old", type: "betaFeedbackCrashSubmissions", created: "2026-10-01T00:00:00Z")
    TestflightFeedback.create!(asc_id: "crash-old", kind: "crash", crash_log: "already have it")
    client = FakeClient.new(
      "/v1/apps" => apps,
      CRASHES => page([ submission("crash-new", type: "betaFeedbackCrashSubmissions", created: "2026-10-28T00:00:00Z") ],
        next_url: "https://api.appstoreconnect.apple.com/v1/apps/#{APP}/betaFeedbackCrashSubmissions?cursor=2"),
      "https://api.appstoreconnect.apple.com/v1/apps/#{APP}/betaFeedbackCrashSubmissions?cursor=2" =>
        page([ old ], next_url: "https://api.appstoreconnect.apple.com/v1/apps/#{APP}/betaFeedbackCrashSubmissions?cursor=3"),
      SCREENSHOTS => page([]),
      "/v1/betaFeedbackCrashSubmissions/crash-new/crashLog" => crash_log
    )

    result = run_poller(client)

    assert_equal 1, result.created
    refute_includes client.paths, "https://api.appstoreconnect.apple.com/v1/apps/#{APP}/betaFeedbackCrashSubmissions?cursor=3"
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

  test "stops asking for a crash log after the retry window" do
    TestflightFeedback.create!(asc_id: "crash-stale", kind: "crash", created_at: 8.days.ago)
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
