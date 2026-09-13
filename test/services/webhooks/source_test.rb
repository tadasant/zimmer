# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Webhooks::SourceTest < ActiveSupport::TestCase
  KEYS = %w[SLACK_TRIGGER_INGEST_MODE SLACK_SIGNING_SECRET].freeze

  setup do
    @saved = KEYS.to_h { |key| [ key, ENV[key] ] }
    KEYS.each { |key| ENV.delete(key) }
    @source = Webhooks::Source.new(name: "slack", mode_key: KEYS[0], secret_key: KEYS[1])
  end

  teardown do
    @saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "with nothing configured the source polls and accepts nothing" do
    assert_equal "poll", @source.mode
    refute_predicate @source, :webhook_enabled?
    refute_predicate @source, :accepting?
  end

  test "a secret alone does not switch the webhook on" do
    ENV["SLACK_SIGNING_SECRET"] = "s3cret"

    refute_predicate @source, :accepting?
  end

  test "the fallback mode alone does not accept deliveries without a secret to verify them" do
    ENV["SLACK_TRIGGER_INGEST_MODE"] = "webhook_with_poll_fallback"

    assert_predicate @source, :webhook_enabled?
    refute_predicate @source, :accepting?
  end

  test "the fallback mode with a secret accepts deliveries" do
    ENV["SLACK_TRIGGER_INGEST_MODE"] = "webhook_with_poll_fallback"
    ENV["SLACK_SIGNING_SECRET"] = "s3cret"

    assert_predicate @source, :accepting?
    assert_equal "s3cret", @source.signing_secret
  end

  test "`webhook` without a poller is not a mode yet, so it polls and says why" do
    ENV["SLACK_TRIGGER_INGEST_MODE"] = "webhook"
    ENV["SLACK_SIGNING_SECRET"] = "s3cret"
    logged = []
    Rails.logger.stubs(:warn).with { |line| logged << line }

    assert_equal "poll", @source.mode
    refute_predicate @source, :accepting?
    assert_match(/#141/, logged.join)
  end

  test "an unrecognised value polls, and warns once rather than on every read" do
    ENV["SLACK_TRIGGER_INGEST_MODE"] = "webhooks"
    logged = []
    Rails.logger.stubs(:warn).with { |line| logged << line }

    3.times { assert_equal "poll", @source.mode }
    assert_equal 1, logged.size
  end

  test "github reads its own settings, polls by default, and serves only github_issue conditions" do
    github = Webhooks::Source.github
    saved = %w[GITHUB_TRIGGER_INGEST_MODE GITHUB_WEBHOOK_SECRET].to_h { |key| [ key, ENV[key] ] }
    saved.each_key { |key| ENV.delete(key) }

    assert_equal [ "github", "GITHUB_TRIGGER_INGEST_MODE", "GITHUB_WEBHOOK_SECRET" ], [ github.name, github.mode_key, github.secret_key ]
    assert_equal "poll", github.mode
    refute_predicate github, :accepting?
    refute github.expects_daily_deliveries
    assert_equal [ "github_issue" ], github.served_conditions.distinct.pluck(:condition_type)
    assert_equal %w[slack github], Webhooks::Source.all.map(&:name)
  ensure
    saved&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
