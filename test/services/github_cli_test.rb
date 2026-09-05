require "test_helper"
require "mocha/minitest"

# GithubCli is the one way Zimmer shells out to `gh`. Its whole job is to make sure a
# hung call — a half-open TCP connection during a GitHub incident, which used to block
# the calling thread forever — arrives at the call site as an ordinary failed call
# rather than as an exception nobody rescued or a wedged singleton (#458).
class GithubCliTest < ActiveSupport::TestCase
  test "passes argv and the caller's timeout straight through to BoundedSubprocess" do
    BoundedSubprocess.expects(:run)
      .with([ "gh", "api", "rate_limit" ], timeout: 7)
      .returns([ "{}", "", fake_process_status(exitstatus: 0) ])

    result = GithubCli.run([ "gh", "api", "rate_limit" ], timeout: 7)

    assert result.success?
    assert_equal "{}", result.stdout
    refute result.timed_out?
  end

  test "a non-zero exit is a failure that names its exit code" do
    BoundedSubprocess.stubs(:run).returns([ "", "HTTP 404", fake_process_status(exitstatus: 1) ])

    result = GithubCli.run([ "gh", "api", "repos/a/b" ], timeout: 5)

    refute result.success?
    refute result.timed_out?
    assert_equal 1, result.exit_code
    assert_includes result.failure_description, "exit status 1"
    assert_includes result.failure_description, "HTTP 404"
  end

  # A nil status is Open3's contract when something else reaps the child before the
  # waiter's waitpid — ZombieReaperJob, in production (#271). Never a success.
  test "a nil status is a failure, and is reported as an unread exit code" do
    BoundedSubprocess.stubs(:run).returns([ "", "gh: connection reset", nil ])

    result = GithubCli.run([ "gh", "api", "repos/a/b" ], timeout: 5)

    refute result.success?
    refute result.timed_out?
    assert_nil result.exit_code
    assert_includes result.failure_description, SubprocessStatus::REAPED_DESCRIPTION
  end

  test "a timeout comes back as a failed Result rather than an exception" do
    BoundedSubprocess.stubs(:run).raises(
      BoundedSubprocess::TimeoutError, "command timed out after 5s (process group killed): gh api repos/a/b"
    )

    result = nil
    assert_nothing_raised { result = GithubCli.run([ "gh", "api", "repos/a/b" ], timeout: 5) }

    assert result.timed_out?
    refute result.success?
    assert_equal "", result.stdout, "a hang produces no output to parse"
  end

  # Callers compare exit codes for meaning — `exit_code == 8` is "checks are pending"
  # in the PR poller. A hang has no exit code, so it must never answer one.
  test "a timed-out call reports no exit code, so no exit-code branch can claim it" do
    BoundedSubprocess.stubs(:run).raises(BoundedSubprocess::TimeoutError, "timed out")

    assert_nil GithubCli.run([ "gh", "pr", "checks", "1" ], timeout: 5).exit_code
  end

  # The failure line these sites used to log for a timeout came from the exception, as
  # "BoundedSubprocess::TimeoutError: …". Keeping that prefix means log greps and alert
  # rules matching "TimeoutError" keep matching now that nothing is raised.
  test "the timeout's failure description keeps the exception class name and message" do
    BoundedSubprocess.stubs(:run).raises(
      BoundedSubprocess::TimeoutError, "command timed out after 5s (process group killed): gh api repos/a/b"
    )

    description = GithubCli.run([ "gh", "api", "repos/a/b" ], timeout: 5).failure_description

    assert_includes description, "BoundedSubprocess::TimeoutError"
    assert_includes description, "command timed out after 5s"
  end

  # Only the timeout is converted. No `gh` binary at all is local and permanent, and
  # GithubSearchService#auth_preflight distinguishes it from a failed request.
  test "Errno::ENOENT still propagates so callers can tell a missing gh from a failed call" do
    BoundedSubprocess.stubs(:run).raises(Errno::ENOENT, "No such file or directory - gh")

    assert_raises(Errno::ENOENT) { GithubCli.run([ "gh", "api", "repos/a/b" ], timeout: 5) }
  end

  # The guard on the invariant this class exists to hold. "Every `gh` invocation goes
  # through GithubCli" is only true while it is true of the newest one, and the failure
  # mode of losing it is exactly what #458 was: an unbounded call nobody notices until a
  # GitHub incident wedges a singleton poller for hours.
  #
  # Comments are stripped before matching, because the files that explain this hazard
  # name `Open3.capture3` and `BoundedSubprocess.run` in prose while calling neither.
  ALLOWED_GH_SHELL_OUT = [ "app/services/github_cli.rb" ].freeze

  test "no code outside GithubCli builds a gh argv and shells out directly" do
    offenders = Dir.glob(Rails.root.join("app/**/*.rb")).filter_map do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s
      next if ALLOWED_GH_SHELL_OUT.include?(relative)

      code = File.readlines(path).reject { |line| line.strip.start_with?("#") }.join
      next unless code.include?('"gh"')
      next unless code.include?("Open3.capture3") || code.include?("BoundedSubprocess.run")

      relative
    end

    assert_empty offenders,
      "these files build a `gh` command and shell out directly; route them through " \
      "GithubCli.run(command, timeout:) so the call is bounded and a timeout is an " \
      "ordinary failed call rather than a wedged singleton (#458)"
  end
end
