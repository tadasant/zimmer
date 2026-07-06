# frozen_string_literal: true

require "test_helper"

class PollBackoffTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:with_pr_url)
    @job_key = "github_pr_poller"
    @base_interval = 30
  end

  # ---- poll_interval bucket logic ----

  test "fresh activity (< 30 min) returns interval 0 (always poll)" do
    stamp_user_activity!(10.minutes.ago)
    assert_equal 0, PollBackoff.poll_interval(@session, base_interval: @base_interval)
  end

  test "warm activity (30 min - 2 hr) returns 2x base interval" do
    stamp_user_activity!(45.minutes.ago)
    assert_equal @base_interval * 2, PollBackoff.poll_interval(@session, base_interval: @base_interval)
  end

  test "cool activity (2-8 hr) returns max(5 min, base)" do
    stamp_user_activity!(4.hours.ago)
    assert_equal 5.minutes.to_i, PollBackoff.poll_interval(@session, base_interval: @base_interval)
  end

  test "cool activity (2-8 hr) respects base when base > 5 min" do
    stamp_user_activity!(4.hours.ago)
    assert_equal 600, PollBackoff.poll_interval(@session, base_interval: 600)
  end

  test "cold activity (8-24 hr) returns max(30 min, base)" do
    stamp_user_activity!(12.hours.ago)
    assert_equal 30.minutes.to_i, PollBackoff.poll_interval(@session, base_interval: @base_interval)
  end

  test "stale activity (> 24 hr) returns 24 hr floor" do
    stamp_user_activity!(2.days.ago)
    assert_equal 24.hours.to_i, PollBackoff.poll_interval(@session, base_interval: @base_interval)
  end

  # ---- should_poll? decisions ----

  test "should_poll? returns true for fresh sessions even without prior poll" do
    stamp_user_activity!(5.minutes.ago)
    assert PollBackoff.should_poll?(@session, job_key: @job_key, base_interval: @base_interval)
  end

  test "should_poll? returns true for stale session with no prior poll" do
    stamp_user_activity!(2.days.ago)
    assert PollBackoff.should_poll?(@session, job_key: @job_key, base_interval: @base_interval)
  end

  test "should_poll? returns false for stale session polled within interval" do
    stamp_user_activity!(2.days.ago)
    stamp_last_polled!(@job_key, 1.hour.ago)
    refute PollBackoff.should_poll?(@session, job_key: @job_key, base_interval: @base_interval)
  end

  test "should_poll? returns true for stale session polled longer than interval ago" do
    stamp_user_activity!(2.days.ago)
    stamp_last_polled!(@job_key, 25.hours.ago)
    assert PollBackoff.should_poll?(@session, job_key: @job_key, base_interval: @base_interval)
  end

  test "should_poll? returns true for warm session polled longer than 2x base ago" do
    stamp_user_activity!(45.minutes.ago)
    stamp_last_polled!(@job_key, (@base_interval * 2 + 5).seconds.ago)
    assert PollBackoff.should_poll?(@session, job_key: @job_key, base_interval: @base_interval)
  end

  test "should_poll? returns false for warm session polled less than 2x base ago" do
    stamp_user_activity!(45.minutes.ago)
    stamp_last_polled!(@job_key, (@base_interval - 5).seconds.ago)
    refute PollBackoff.should_poll?(@session, job_key: @job_key, base_interval: @base_interval)
  end

  test "should_poll? handles unparseable last_polled_at by polling" do
    stamp_user_activity!(2.days.ago)
    @session.update!(custom_metadata: { "github_pull_request_urls" => [ "x" ], "poller_last_polled_at" => { @job_key => "garbage" } })
    assert PollBackoff.should_poll?(@session, job_key: @job_key, base_interval: @base_interval)
  end

  test "should_poll? isolates by job_key (other jobs' polls do not gate this one)" do
    stamp_user_activity!(2.days.ago)
    stamp_last_polled!("github_comment_poller", 1.hour.ago)
    # Different job_key — backoff for github_pr_poller is unaffected
    assert PollBackoff.should_poll?(@session, job_key: @job_key, base_interval: @base_interval)
  end

  # ---- record_poll! ----

  test "record_poll! writes ISO8601 timestamp under poller_last_polled_at[job_key]" do
    freeze_time do
      PollBackoff.record_poll!(@session, job_key: @job_key)
      @session.reload
      assert_equal Time.current.iso8601, @session.custom_metadata.dig("poller_last_polled_at", @job_key)
    end
  end

  test "record_poll! preserves entries for other jobs" do
    @session.update!(custom_metadata: (@session.custom_metadata || {}).merge(
      "poller_last_polled_at" => { "github_comment_poller" => 5.minutes.ago.iso8601 }
    ))
    PollBackoff.record_poll!(@session, job_key: @job_key)
    @session.reload
    assert @session.custom_metadata.dig("poller_last_polled_at", "github_comment_poller").present?
    assert @session.custom_metadata.dig("poller_last_polled_at", @job_key).present?
  end

  test "record_poll! preserves other custom_metadata fields" do
    PollBackoff.record_poll!(@session, job_key: @job_key)
    @session.reload
    assert_equal [ "https://github.com/owner/repo/pull/123" ], @session.custom_metadata["github_pull_request_urls"]
  end

  private

  def stamp_user_activity!(at)
    @session.update!(metadata: (@session.metadata || {}).merge("last_user_activity_at" => at.iso8601))
  end

  def stamp_last_polled!(job_key, at)
    last = (@session.custom_metadata&.dig("poller_last_polled_at") || {}).merge(job_key => at.iso8601)
    @session.update!(custom_metadata: (@session.custom_metadata || {}).merge("poller_last_polled_at" => last))
  end
end
