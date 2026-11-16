# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# GithubTriggerPollerJob at a configured poll interval (GithubTriggerPollCadence). At the one-minute
# default every window is the tick count it always was — github_trigger_poller_job_test.rb covers
# that path in full. This covers what changes when the poller is slowed: one sweep per interval,
# and a removal grace and a degradation page that stay roughly the same length in TIME.
class GithubTriggerPollerCadenceTest < ActiveJob::TestCase
  KEY = GithubTriggerPollCadence::SETTING_KEY
  LABELLED = [ { "number" => 7, "title" => "Item 7", "html_url" => "https://github.com/tadasant/zimmer/pull/7",
                 "repository_url" => "https://api.github.com/repos/tadasant/zimmer", "user" => { "login" => "someone" },
                 "body" => "b", "labels" => [ { "name" => "ready to merge" } ], "created_at" => "2026-07-10T12:00:00Z",
                 "pull_request" => { "url" => "x" } } ].freeze

  setup do
    @label_condition = trigger_conditions(:github_label_condition)
    GithubSearchService.stubs(:auth_preflight)
      .returns(GithubSearchService::PreflightResult.new(GithubSearchService::PREFLIGHT_AUTHENTICATED, nil))
    @saved = ENV[KEY]
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    @saved.nil? ? ENV.delete(KEY) : ENV[KEY] = @saved
    Rails.cache = @original_cache
  end

  def interval(minutes)
    ENV[KEY] = minutes.to_s
  end

  # One sweep, +minutes+ after the last, with the label search returning +label+.
  def sweep(label:, after: nil)
    travel(after) if after
    fake = ->(query, **_opts) { query.start_with?("is:issue ") ? [] : label }
    GithubSearchService.stub(:search_issues, fake) { GithubTriggerPollerJob.perform_now }
  end

  def seen = @label_condition.reload.github_seen_items

  # The number of consecutive missing sweeps it takes, at +minutes+, to drop a seen key.
  def misses_to_drop(minutes)
    interval(minutes)
    sweep(label: LABELLED)
    assert_equal [ "tadasant/zimmer#7:ready to merge" ], seen

    (1..10).each do |misses|
      sweep(label: [], after: minutes.minutes)
      return misses if seen.empty?
    end
    flunk "the key was never dropped"
  end

  test "the removal grace is three misses at one minute, as it always was" do
    assert_equal 3, misses_to_drop(1)
  end

  test "at five minutes the grace is two misses: one blip never drops a key, and no 15-minute wait" do
    assert_equal 2, misses_to_drop(5)
  end

  test "at fifteen minutes a removal registers on the second miss, fifteen minutes after the first" do
    assert_equal 2, misses_to_drop(15)
  end

  test "a slowed poller sweeps once per interval although the cron enqueues every minute" do
    interval(15)
    searches = 0
    fake = lambda do |_query, **_opts|
      searches += 1
      []
    end

    GithubSearchService.stub(:search_issues, fake) do
      GithubTriggerPollerJob.perform_now
      after_first = searches
      assert_operator after_first, :>, 0

      14.times do
        travel 1.minute
        GithubTriggerPollerJob.perform_now
      end
      assert_equal after_first, searches, "no sweep inside the interval"

      travel 1.minute
      GithubTriggerPollerJob.perform_now
      assert_equal after_first * 2, searches, "the next sweep, one interval after the first"
    end
  end

  test "at the default every enqueued tick sweeps" do
    ENV.delete(KEY)
    searches = 0
    fake = lambda do |_query, **_opts|
      searches += 1
      []
    end

    GithubSearchService.stub(:search_issues, fake) do
      GithubTriggerPollerJob.perform_now
      per_sweep = searches
      assert_operator per_sweep, :>, 0

      2.times { GithubTriggerPollerJob.perform_now }
      assert_equal per_sweep * 3, searches, "three ticks in the same minute are three sweeps"
    end
  end

  test "at fifteen minutes an incomplete search index pages on the second degraded sweep, not the fifth" do
    interval(15)
    titles = []
    ErrorReporter.stubs(:report_exception).with { |_error, **kwargs| titles << kwargs[:context][:title] }
    incomplete = lambda do |query, **_opts|
      raise GithubSearchService::IncompleteResultsError, "incomplete for #{query}" if query.start_with?("is:open ")

      []
    end

    GithubSearchService.stub(:search_issues, incomplete) { GithubTriggerPollerJob.perform_now }
    assert_empty titles, "one degraded sweep is still a blip"

    travel 15.minutes
    GithubSearchService.stub(:search_issues, incomplete) { GithubTriggerPollerJob.perform_now }
    assert_includes titles, "GitHub search index degraded"
  end
end
