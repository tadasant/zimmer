# frozen_string_literal: true

# Recorded-shape App Store Connect documents for the TestFlight feedback poller,
# trimmed to the fields it reads. The shapes follow Apple's OpenAPI spec 4.5.1:
# `GET /v1/apps`, `GET /v1/apps/{id}/betaFeedbackCrashSubmissions` (and the
# screenshot twin) with `include=build`, and
# `GET /v1/betaFeedbackCrashSubmissions/{id}/crashLog`.
module AppStoreConnectFixtures
  APP_ID = "6740000000"

  CRASH_LOG = <<~LOG
    Incident Identifier: 1F0C1D7E-0000-4000-8000-000000000001
    Hardware Model:      iPhone16,2
    Process:             Zimmer [812]
    Version:             1.4 (212)
    OS Version:          iPhone OS 26.1 (23B85)

    Exception Type:  EXC_CRASH (SIGABRT)
    Exception Codes: 0x0000000000000000, 0x0000000000000000
    Termination Reason: SIGNAL 6 Abort trap: 6
    Triggered by Thread:  0

    Crashed Thread:  0
    0   libsystem_kernel.dylib  0x1e5f0 __pthread_kill + 8
    1   Zimmer                   0x4a1c0 CarPlaySceneDelegate.templateApplicationScene(_:didConnect:to:) + 412
  LOG

  module_function

  def apps(bundle_id: "com.tadasant.zimmer")
    {
      "data" => [
        { "type" => "apps", "id" => "999", "attributes" => { "bundleId" => "#{bundle_id}.widgets" } },
        { "type" => "apps", "id" => APP_ID, "attributes" => { "bundleId" => bundle_id } }
      ]
    }
  end

  def submission(id, type:, created:, build_id: "b-212", comment: nil, **extra)
    {
      "type" => type,
      "id" => id,
      "attributes" => {
        "createdDate" => created,
        "comment" => comment,
        "email" => "tester@example.com",
        "deviceModel" => "iPhone16,2",
        "osVersion" => "26.1",
        "deviceFamily" => "IPHONE",
        "batteryPercentage" => 81
      }.merge(extra),
      "relationships" => { "build" => { "data" => { "type" => "builds", "id" => build_id } } }
    }
  end

  def page(data, next_url: nil)
    {
      "data" => data,
      "included" => [ { "type" => "builds", "id" => "b-212", "attributes" => { "version" => "212" } } ],
      "links" => { "self" => "https://api.appstoreconnect.apple.com/v1/x", "next" => next_url }.compact
    }
  end

  def crash_log(text = CRASH_LOG)
    { "data" => { "type" => "betaCrashLogs", "id" => "log-1", "attributes" => { "logText" => text } } }
  end

  # A stand-in for AppStoreConnect::Client: answers `get` from a table of
  # path → document (or → exception), and records every call.
  class FakeClient
    attr_reader :calls

    def initialize(routes)
      @routes = routes
      @calls = []
    end

    def get(path, params = {})
      @calls << [ path, params ]
      answer = @routes.fetch(path) { raise "unexpected App Store Connect request: #{path}" }
      answer = answer.call if answer.respond_to?(:call)
      raise answer if answer.is_a?(Exception)

      answer
    end

    def paths = @calls.map(&:first)
  end

  class RecordingExporter
    attr_reader :records

    def initialize = @records = []
    def enqueue(record) = @records << record
  end
end
