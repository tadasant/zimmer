# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# GithubRateLimit is the breaker GithubCli applies before spending
# any of GitHub's budgets. The case it exists for is 2026-11-15: the REST core budget ran out,
# and Zimmer's callers sent 586 more calls in 19 minutes, every one refused and every one counted.
class GithubRateLimitTest < ActiveSupport::TestCase
  include GithubSearchStderrFixtures

  # GithubRateLimit reads GH_TOKEN and GH_TOKEN__<OWNER> from ENV, as GithubTokens does.
  # Each test sets exactly the tokens it means, and teardown puts ENV back.
  GH_VARIABLES = ->(keys) { keys.select { |key| key == "GH_TOKEN" || key.start_with?("GH_TOKEN__") } }

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @original_env = GH_VARIABLES.call(ENV.keys).to_h { |key| [ key, ENV[key] ] }
    set_tokens("GH_TOKEN" => "ghp_default_token_for_tests")
  end

  teardown do
    Rails.cache = @original_cache
    GH_VARIABLES.call(ENV.keys).each { |key| ENV.delete(key) }
    @original_env.each { |key, value| ENV[key] = value }
  end

  def set_tokens(vars)
    GH_VARIABLES.call(ENV.keys).each { |key| ENV.delete(key) }
    vars.each { |key, value| ENV[key] = value }
  end

  def status(ok) = fake_process_status(exitstatus: ok ? 0 : 1)

  def rate_limit_json(core_remaining:, reset_at:, search_remaining: 30, graphql_remaining: 5000)
    {
      "resources" => {
        "core" => { "limit" => 5000, "remaining" => core_remaining, "reset" => reset_at.to_i },
        "search" => { "limit" => 30, "remaining" => search_remaining, "reset" => (Time.current + 60).to_i },
        "graphql" => { "limit" => 5000, "remaining" => graphql_remaining, "reset" => reset_at.to_i }
      }
    }.to_json
  end

  def probe?(command) = command == [ "gh", "api", "rate_limit" ]

  # --- which budget a call spends ---------------------------------------------------

  test "resource_for sorts gh argv into GitHub's budgets, and exempts the free probe" do
    assert_equal "core", GithubRateLimit.resource_for(%w[gh api repos/a/b/issues/1/comments])
    assert_equal "core", GithubRateLimit.resource_for(%w[gh auth status --json hosts])
    assert_equal "graphql", GithubRateLimit.resource_for(%w[gh pr view 1 --repo a/b --json state])
    assert_equal "graphql", GithubRateLimit.resource_for(%w[gh api graphql -f query=x])
    assert_equal "search", GithubRateLimit.resource_for([ "gh", "api", "-X", "GET", "search/issues", "--raw-field", "q=x" ])
    assert_nil GithubRateLimit.resource_for(%w[gh api rate_limit])
    assert_nil GithubRateLimit.resource_for(%w[gh auth token]), "local: never refused"
    assert_nil GithubRateLimit.resource_for(%w[gh --version])
    assert_equal "search", GithubRateLimit.resource_for(%w[gh search prs foo])
    assert_equal "graphql", GithubRateLimit.resource_for(%w[gh repo view a/b])
    assert_nil GithubRateLimit.resource_for(%w[git status])
  end

  # --- the breaker -------------------------------------------------------------------

  test "the first primary rate-limit refusal trips the breaker, and later calls never reach GitHub" do
    reset_at = 17.minutes.from_now
    calls = []
    BoundedSubprocess.stubs(:run).with do |command, **|
      calls << command
      true
    end.returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 0, reset_at: reset_at), "", status(true) ])

    first = GithubCli.run(%w[gh api repos/tadasant/zimmer/issues/1/comments], timeout: 5)
    refute first.success?
    refute first.refused?, "the call that met the limit was really sent"
    assert_equal [ %w[gh api repos/tadasant/zimmer/issues/1/comments], %w[gh api rate_limit] ], calls

    BoundedSubprocess.expects(:run).never
    second = GithubCli.run(%w[gh api repos/tadasant/zimmer/pulls/2], timeout: 5)

    assert second.refused?
    refute second.success?
    assert_nil second.exit_code, "a refused call has no exit code to read meaning into"
    assert_equal "core", second.refusal.resource
    assert_equal reset_at.to_i, second.refusal.reset_at.to_i
    assert_includes second.failure_description, "not sent to GitHub"
    assert_includes second.failure_description, reset_at.utc.iso8601
    refute_includes second.failure_description, "ghp_", "the token never appears in a message"
  end

  test "a spent core budget does not stop the search budget the trigger poller spends" do
    reset_at = 10.minutes.from_now
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 0, reset_at: reset_at), "", status(true) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)

    assert GithubRateLimit.refusal_for(%w[gh api repos/a/b])
    assert_nil GithubRateLimit.refusal_for([ "gh", "api", "-X", "GET", "search/issues" ]),
               "search has its own budget; the poller's sweep must keep running"
    assert_nil GithubRateLimit.refusal_for(%w[gh pr view 1 --repo a/b]),
               "graphql still had budget in the probe"
  end

  test "the breaker reopens at GitHub's reset time" do
    reset_at = 5.minutes.from_now
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 0, reset_at: reset_at), "", status(true) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)
    assert GithubRateLimit.refusal_for(%w[gh api repos/a/b])

    travel_to(reset_at + 1.second) do
      assert_nil GithubRateLimit.refusal_for(%w[gh api repos/a/b])
    end
  end

  test "a secondary rate limit does not trip the breaker: the probe shows budget left" do
    BoundedSubprocess.stubs(:run).returns([ "", SECONDARY_RATE_LIMIT, status(false) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)

    assert_nil GithubRateLimit.refusal_for(%w[gh api repos/a/b])
  end

  test "rate-limit prose that the probe contradicts trips nothing" do
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 4000, reset_at: 30.minutes.from_now), "", status(true) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)

    assert_nil GithubRateLimit.refusal_for(%w[gh api repos/a/b])
  end

  test "when the probe fails too, the breaker holds briefly rather than not at all" do
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)

    refusal = GithubRateLimit.refusal_for(%w[gh api repos/a/b])
    assert refusal
    assert_in_delta GithubRateLimit::FALLBACK_HOLD.from_now.to_i, refusal.reset_at.to_i, 2

    travel_to(GithubRateLimit::FALLBACK_HOLD.from_now + 1.second) do
      assert_nil GithubRateLimit.refusal_for(%w[gh api repos/a/b])
    end
  end

  test "breakers are per credential: one owner's spent token does not stop another's" do
    set_tokens("GH_TOKEN" => "ghp_default_token_for_tests", "GH_TOKEN__PULSEMCP" => "ghp_pulsemcp_token")
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 0, reset_at: 20.minutes.from_now), "", status(true) ])

    GithubCli.run(%w[gh api repos/pulsemcp/x/pulls/1], timeout: 5)

    refusal = GithubRateLimit.refusal_for(%w[gh api repos/pulsemcp/x], env: { "GH_TOKEN" => "ghp_pulsemcp_token" })
    assert refusal
    assert_equal "GH_TOKEN__PULSEMCP", refusal.credential
    assert_nil GithubRateLimit.refusal_for(%w[gh api repos/tadasant/zimmer]),
               "the default token's budget was never spent"
  end

  test "the breaker logs once when it opens, not once per refused call" do
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 0, reset_at: 20.minutes.from_now), "", status(true) ])

    entries = capture_log_entries do
      GithubCli.run(%w[gh api repos/a/b], timeout: 5)
      5.times { GithubCli.run(%w[gh api repos/a/b], timeout: 5) }
    end

    opened = entries.select { |_severity, message| message.include?("[GithubRateLimit] GitHub's core rate limit is spent") }
    assert_equal 1, opened.size
    assert_equal "WARN", opened.first.first
  end

  test "a cache that raises lets the call through" do
    Rails.cache.stubs(:read).raises(RuntimeError, "cache down")

    assert_nil GithubRateLimit.refusal_for(%w[gh api repos/a/b])
  end

  test "a GithubCli call for an owner is refused by that owner's breaker, not the default token's" do
    set_tokens("GH_TOKEN" => "ghp_default_token_for_tests", "GH_TOKEN__PULSEMCP" => "ghp_pulsemcp_token")
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 0, reset_at: 20.minutes.from_now), "", status(true) ])
    GithubCli.run(%w[gh api repos/pulsemcp/x/pulls/1], timeout: 5)

    BoundedSubprocess.unstub(:run)
    BoundedSubprocess.expects(:run).never
    assert GithubCli.run(%w[gh api repos/pulsemcp/y/pulls/2], timeout: 5).refused?

    BoundedSubprocess.unstub(:run)
    BoundedSubprocess.expects(:run).once.returns([ "{}", "", status(true) ])
    refute GithubCli.run(%w[gh api repos/tadasant/zimmer/pulls/3], timeout: 5).refused?,
           "the default token's budget was never spent"
  end

  test "a budget with calls left is never refused, however low" do
    BoundedSubprocess.stubs(:run).returns(
      [ rate_limit_json(core_remaining: 3, reset_at: 25.minutes.from_now), "", status(true) ]
    )
    GithubRateLimitSnapshotJob.perform_now

    assert_nil GithubRateLimit.refusal_for(%w[gh api repos/a/b])
    assert_includes GithubRateLimit.diagnosis, "GH_TOKEN's core budget is down to 3/5000",
                    "but the page names it, so a stall just before exhaustion still says why"
  end

  test "a snapshot that has aged out is not reported" do
    BoundedSubprocess.stubs(:run).returns(
      [ rate_limit_json(core_remaining: 10, reset_at: 50.minutes.from_now), "", status(true) ]
    )
    GithubRateLimitSnapshotJob.perform_now

    travel_to(GithubRateLimit::SNAPSHOT_TTL.from_now + 1.second) do
      assert_nil GithubRateLimit.diagnosis
    end
  end

  test "the snapshot job trips the breaker on a budget that is already spent" do
    BoundedSubprocess.stubs(:run).returns(
      [ rate_limit_json(core_remaining: 0, reset_at: 9.minutes.from_now), "", status(true) ]
    )
    GithubRateLimitSnapshotJob.perform_now

    refusal = GithubRateLimit.refusal_for(%w[gh auth status --json hosts])
    assert_equal "core", refusal.resource, "known spent before any caller was refused"
  end

  # --- the diagnosis -----------------------------------------------------------------

  test "diagnosis names a spent budget and its reset, and is nil when nothing is known" do
    assert_nil GithubRateLimit.diagnosis

    reset_at = 12.minutes.from_now
    BoundedSubprocess.stubs(:run).returns(
      [ rate_limit_json(core_remaining: 0, reset_at: reset_at), "", status(true) ]
    )
    GithubRateLimitSnapshotJob.perform_now

    diagnosis = GithubRateLimit.diagnosis
    assert_includes diagnosis, "GH_TOKEN's core budget is spent until #{reset_at.utc.iso8601}"
    assert_includes diagnosis, "agent sessions running `gh` as the same user"
  end
end
