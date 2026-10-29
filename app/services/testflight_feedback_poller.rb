# frozen_string_literal: true

# Pulls the Zimmer iOS app's TestFlight feedback out of App Store Connect and
# into `testflight_feedbacks`: crash submissions with their crash logs, and
# screenshot submissions.
#
# One pass, newest first:
#
# 1. Find the app by bundle id.
# 2. For each kind, page through the app's submissions sorted by
#    `-createdDate`, inserting the ones not already stored, and stop at the
#    first page holding nothing new — everything older was stored by an
#    earlier pass. MAX_PAGES bounds a first run against a long history.
# 3. Fetch the crash log of every stored crash that does not have one yet and
#    is recent enough to keep asking about (CRASH_LOG_RETRY_WINDOW). A crash
#    log can lag its submission, so a 404 leaves the row for the next pass.
#
# Idempotent by construction: the unique index on `asc_id` is the dedupe, an
# insert that loses a race is a no-op, and a crash log is only ever written
# into a row that has none.
#
# Each newly stored crash also goes on the shipped log stream as one WARN
# record under scope `ios.crash` — beside the `ios.live` call telemetry — so a
# crash reads in time order with what the app reported around it. The record
# is a pointer and a headline, never the log or the tester's comment; the full
# text is in the table, read with the `get_testflight_crashes` MCP tool.
class TestflightFeedbackPoller
  DEFAULT_BUNDLE_ID = "com.tadasant.zimmer"
  PAGE_SIZE = 50
  MAX_PAGES = 10
  CRASH_LOG_RETRY_WINDOW = 7.days
  LOG_SCOPE = "ios.crash"

  # kind → the App Store Connect relationship listing it.
  SOURCES = {
    "crash" => "betaFeedbackCrashSubmissions",
    "screenshot" => "betaFeedbackScreenshotSubmissions"
  }.freeze

  Result = Data.define(:created, :crash_logs_fetched, :crash_logs_pending)

  def self.bundle_id = ENV.fetch("TESTFLIGHT_BUNDLE_ID", "").presence || DEFAULT_BUNDLE_ID

  def initialize(client:, bundle_id: self.class.bundle_id, exporter: OtelLogsExporter.instance, logger: Rails.logger)
    @client = client
    @bundle_id = bundle_id
    @exporter = exporter
    @logger = logger
  end

  def run
    app_id = find_app_id
    created = SOURCES.sum { |kind, relationship| import(kind, relationship, app_id) }
    fetched, pending = fetch_crash_logs
    Result.new(created: created, crash_logs_fetched: fetched, crash_logs_pending: pending)
  end

  private

  def find_app_id
    document = @client.get("/v1/apps", { "filter[bundleId]" => @bundle_id, "fields[apps]" => "bundleId", "limit" => "200" })
    # `filter[bundleId]` also matches ids the value is a prefix of, so compare exactly.
    app = Array(document["data"]).find { |entry| entry.dig("attributes", "bundleId") == @bundle_id }
    raise AppStoreConnect::Client::Error, "no App Store Connect app has bundle id #{@bundle_id}" unless app

    app["id"]
  end

  def import(kind, relationship, app_id)
    created = 0
    next_url = nil

    MAX_PAGES.times do |page|
      document = if page.zero?
        @client.get("/v1/apps/#{app_id}/#{relationship}",
          { "sort" => "-createdDate", "limit" => PAGE_SIZE.to_s, "include" => "build", "fields[builds]" => "version" })
      else
        @client.get(next_url)
      end

      submissions = Array(document["data"])
      builds = build_numbers(document["included"])
      known = TestflightFeedback.where(asc_id: submissions.map { |s| s["id"] }).pluck(:asc_id).to_set
      fresh = submissions.reject { |submission| known.include?(submission["id"]) }

      fresh.each { |submission| created += 1 if store(kind, submission, builds) }

      next_url = document.dig("links", "next")
      break if fresh.empty? || next_url.blank?
    end

    created
  end

  def build_numbers(included)
    Array(included).each_with_object({}) do |resource, numbers|
      numbers[resource["id"]] = resource.dig("attributes", "version") if resource["type"] == "builds"
    end
  end

  # @return [Boolean] whether this pass created the row
  def store(kind, submission, builds)
    attributes = submission["attributes"] || {}
    build_id = submission.dig("relationships", "build", "data", "id")
    row = TestflightFeedback.create!(
      asc_id: submission["id"],
      kind: kind,
      submitted_at: parse_time(attributes["createdDate"]),
      build_number: builds[build_id],
      device_model: attributes["deviceModel"],
      os_version: attributes["osVersion"],
      comment: attributes["comment"],
      tester_email: attributes["email"],
      raw_attributes: attributes
    )
    @logger.info("[testflight] stored #{kind} submission #{row.asc_id} (build #{row.build_number || '?'})")
    true
  rescue ActiveRecord::RecordNotUnique
    false
  end

  def fetch_crash_logs
    fetched = 0
    pending = 0

    TestflightFeedback.awaiting_crash_log(since: CRASH_LOG_RETRY_WINDOW.ago).find_each do |row|
      document = @client.get("/v1/betaFeedbackCrashSubmissions/#{row.asc_id}/crashLog", { "fields[betaCrashLogs]" => "logText" })
      text = document.dig("data", "attributes", "logText")
      if text.blank?
        pending += 1
        next
      end

      updated = TestflightFeedback.where(id: row.id, crash_log: nil).update_all(crash_log: text, crash_log_fetched_at: Time.current, updated_at: Time.current)
      next if updated.zero?

      fetched += 1
      ship(row.reload)
    rescue AppStoreConnect::Client::NotFound
      pending += 1
    end

    [ fetched, pending ]
  end

  def ship(row)
    return unless @exporter

    @exporter.enqueue(
      timestamp: (row.submitted_at || row.created_at).to_f,
      severity: "WARN",
      scope: LOG_SCOPE,
      body: "[ios.crash] TestFlight crash #{row.asc_id} build=#{row.build_number || '?'} device=#{row.device_model || '?'} " \
            "os=#{row.os_version || '?'}#{" — #{row.headline}" if row.headline} (full log: get_testflight_crashes id=#{row.asc_id})",
      attributes: {
        "event" => "testflight.crash",
        "asc_id" => row.asc_id,
        "build_number" => row.build_number,
        "device_model" => row.device_model,
        "os_version" => row.os_version,
        "headline" => row.headline,
        "crash_log_chars" => row.crash_log.length
      }.compact
    )
  rescue ThreadError
    # The exporter's queue is full; the row is the record, the log line is a convenience.
    nil
  end

  def parse_time(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
end
