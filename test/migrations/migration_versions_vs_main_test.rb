# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# Runs .github/scripts/migration-versions-vs-main.rb for real: a throwaway git
# repo stands in for `main`, and a `gh` stub on PATH stands in for the GitHub API,
# answering the PR files endpoint and recording every status it is asked to post.
class MigrationVersionsVsMainTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join(".github/scripts/migration-versions-vs-main.rb").to_s

  MAIN = [
    "db/migrate/20261110000000_add_gadget.rb",
    "db/migrate/20261111120000_add_author_to_live_conversation_turns.rb"
  ].freeze

  test "check fails a PR whose new migration shares a version with current main" do
    output, status = run_script("check", "--pr", "1484", "--main-ref", "HEAD",
      files: { 1484 => "added\tdb/migrate/20261111120000_create_mcp_event_webhook_subscriptions.rb\t\n" })

    assert_not_predicate status, :success?
    assert_includes output, "Merging PR #1484 into HEAD as it stands now would collide"
    assert_includes output, "db/migrate/20261111120000_add_author_to_live_conversation_turns.rb"
    assert_includes output, "db/migrate/20261111120000_create_mcp_event_webhook_subscriptions.rb"
  end

  test "check passes a PR that renumbers its migration away, and ignores files outside db/migrate" do
    output, status = run_script("check", "--pr", "1499", "--main-ref", "HEAD",
      files: { 1499 => "renamed\tdb/migrate/20261113070000_create_x.rb\tdb/migrate/20261111120000_create_x.rb\n" \
                       "added\tapp/models/20261111120000_not_a_migration.rb\t\n" })

    assert_predicate status, :success?, output
    assert_includes output, "adds no migration that collides"
  end

  # Fail closed: a check that could not read the PR has not passed it.
  test "check fails when the API cannot be read" do
    output, status = run_script("check", "--pr", "7", "--main-ref", "HEAD", files: {})

    assert_not_predicate status, :success?
    assert_includes output, "failed"
  end

  test "sweep writes a status to every open PR that adds a migration, and only those" do
    output, status, posted = run_script("sweep", "--main-ref", "HEAD", "--target-url", "https://example.test/run",
      prs: prs_json([ 1484, "aaaa1484", [ "ready to merge", "agent-filed" ] ], [ 1490, "bbbb1490", [ "ready to merge" ] ], [ 1491, "cccc1491", [] ]),
      files: {
        1484 => "added\tdb/migrate/20261111120000_create_mcp_event_webhook_subscriptions.rb\t\n",
        1490 => "added\tdb/migrate/20261114000000_add_doodad.rb\t\n",
        1491 => "modified\tapp/models/session.rb\t\n"
      })

    assert_predicate status, :success?, output
    statuses = posted.lines(chomp: true)
    assert_equal 2, statuses.size, posted

    failure = statuses.find { |line| line.include?("statuses/aaaa1484") }
    assert_includes failure, "state=failure"
    assert_includes failure, "context=migration versions vs main"
    assert_includes failure, "20261111120000"
    assert_includes failure, "target_url=https://example.test/run"

    success = statuses.find { |line| line.include?("statuses/bbbb1490") }
    assert_includes success, "state=success"

    assert_not statuses.any? { |line| line.include?("cccc1491") }, "a PR that adds no migration got a status"
  end

  # The status blocks nothing on its own — the ruleset requires only
  # `all-checks-pass` — so the label the merge gate keys on comes off, and only
  # from the PR that collides.
  test "sweep re-runs a colliding PR's CI, and takes ready to merge off it with a comment first" do
    output, status, _posted, edits = run_script("sweep", "--main-ref", "HEAD",
      prs: prs_json([ 1484, "aaaa1484", [ "ready to merge" ] ], [ 1490, "bbbb1490", [ "ready to merge" ] ], [ 1492, "dddd1492", [] ]),
      files: {
        1484 => "added\tdb/migrate/20261111120000_create_mcp_event_webhook_subscriptions.rb\t\n",
        1490 => "added\tdb/migrate/20261114000000_add_doodad.rb\t\n",
        1492 => "added\tdb/migrate/20261111120000_create_other.rb\t\n"
      })

    assert_predicate status, :success?, output
    edits = edits.lines(chomp: true)
    comment = edits.index { |line| line.start_with?("pr comment 1484") && line.include?("20261111120000") }
    unlabel = edits.index("pr edit 1484 --repo tadasant/zimmer --remove-label ready to merge")
    assert comment && unlabel && comment < unlabel, "expected the comment, then the label removal: #{edits.inspect}"

    # Both colliding PRs get CI re-run, labelled or not; the clean one does not.
    assert_includes edits, "run rerun run-aaaa1484 --repo tadasant/zimmer"
    assert_includes edits, "run rerun run-dddd1492 --repo tadasant/zimmer"
    assert_not edits.any? { |line| line.include?("bbbb1490") || line.include?(" 1490 ") }, "a clean PR was touched"
    assert_not edits.any? { |line| line.start_with?("pr ") && line.include?(" 1492 ") },
      "a colliding PR with no label to remove was commented on"
  end

  # One unreadable PR must not leave the rest unchecked — that is the gap this
  # workflow exists to close — but the job still goes red for it.
  test "sweep checks every PR even when one cannot be read, and then fails" do
    output, status, posted = run_script("sweep", "--main-ref", "HEAD",
      prs: prs_json([ 1, "aaaa0001", [] ], [ 1490, "bbbb1490", [] ]),
      files: { 1490 => "added\tdb/migrate/20261114000000_add_doodad.rb\t\n" })

    assert_not_predicate status, :success?
    assert_includes output, "#1: could not check"
    assert_includes posted, "statuses/bbbb1490"
  end

  test "a transient failure reading a PR's files is retried, and a later success is the answer" do
    run = run_retrying("sweep", failures: { "/pulls/1490/files" => [ SERVER_ERROR, SERVER_ERROR ] },
      prs: prs_json([ 1490, "bbbb1490", [] ]), files: { 1490 => CLEAN_ROW })

    assert_predicate run.status, :success?, run.output
    assert_includes run.posted, "statuses/bbbb1490"
    assert_includes run.posted, "state=success"
    assert_includes run.output, "attempt 2 of 5"
    assert_equal [ 2, 5 ], run.slept
    assert_equal 3, run.calls_matching("/pulls/1490/files").size
  end

  # `--paginate` can print some pages before a later one fails. Those rows belong
  # to the failed attempt, and only the successful attempt's rows are read.
  test "a retried read is judged on the successful attempt alone" do
    run = run_retrying("sweep", failures: { "/pulls/1490/files" => [ [ COLLIDING_ROW, SERVER_ERROR ] ] },
      prs: prs_json([ 1490, "bbbb1490", [] ]), files: { 1490 => CLEAN_ROW })

    assert_predicate run.status, :success?, run.output
    assert_includes run.posted, "state=success"
    assert_not_includes run.posted, "state=failure"
  end

  test "a collision found after a retry still fails the PR, re-runs its CI and takes the label off" do
    run = run_retrying("sweep", failures: { "/pulls/1484/files" => [ SERVER_ERROR ] },
      prs: prs_json([ 1484, "aaaa1484", [ "ready to merge" ] ]), files: { 1484 => COLLIDING_ROW })

    assert_predicate run.status, :success?, run.output
    assert_includes run.posted, "state=failure"
    assert_includes run.edits, "run rerun run-aaaa1484"
    assert_includes run.edits, "--remove-label ready to merge"
  end

  # Riding out a blip must not become silence about an outage.
  test "sweep still fails, with no status for the PR, when the failure outlasts the retries" do
    run = run_retrying("sweep", failures: { "/pulls/1/files" => [ SERVER_ERROR ] * 50 },
      prs: prs_json([ 1, "aaaa0001", [] ], [ 1490, "bbbb1490", [] ]),
      files: { 1 => CLEAN_ROW, 1490 => CLEAN_ROW })

    assert_not_predicate run.status, :success?
    assert_includes run.output, "#1: could not check"
    assert_includes run.output, "gave up after 5 attempts"
    assert_includes run.output, "Could not check #1; see above."
    assert_not_includes run.posted, "aaaa0001"
    assert_includes run.posted, "statuses/bbbb1490"
    assert_equal [ 2, 5, 10, 20 ], run.slept
  end

  test "sweep fails when the list of open PRs cannot be read once the retries are spent" do
    run = run_retrying("sweep", failures: { "pr list" => [ SERVER_ERROR ] * 50 }, files: {})

    assert_not_predicate run.status, :success?
    assert_includes run.output, "gave up after 5 attempts"
  end

  test "check rides out a transient failure, and fails when it outlasts the retries" do
    recovered = run_retrying("check", "--pr", "1490", failures: { "/pulls/1490/files" => [ SERVER_ERROR ] },
      files: { 1490 => CLEAN_ROW })
    assert_predicate recovered.status, :success?, recovered.output

    spent = run_retrying("check", "--pr", "1490", failures: { "/pulls/1490/files" => [ SERVER_ERROR ] * 50 },
      files: { 1490 => CLEAN_ROW })
    assert_not_predicate spent.status, :success?
    assert_includes spent.output, "gave up after 5 attempts"
  end

  test "each transient failure gh reports is retried" do
    [
      "HTTP 502: 502 Bad Gateway (https://api.github.com/graphql)",
      "gh: HTTP 504",
      "HTTP 429: Too Many Requests (https://api.github.com/graphql)",
      "non-200 OK status code: 503 Service Unavailable body: \"\"",
      "GraphQL: Something went wrong while executing your query. This may be the result of a timeout",
      "error connecting to api.github.com",
      "Get \"https://api.github.com/x\": read tcp 10.0.0.1:1->10.0.0.2:443: read: connection reset by peer",
      "Get \"https://api.github.com/x\": dial tcp 10.0.0.2:443: i/o timeout",
      "Get \"https://api.github.com/x\": net/http: TLS handshake timeout",
      "Post \"https://api.github.com/graphql\": unexpected EOF"
    ].each do |message|
      run = run_retrying("check", "--pr", "1490", failures: { "/pulls/1490/files" => [ message ] }, files: { 1490 => CLEAN_ROW })
      assert_predicate run.status, :success?, "not retried: #{message}\n#{run.output}"
      assert_equal [ 2 ], run.slept, message
    end
  end

  test "a permanent failure is not retried" do
    [
      "gh: Not Found (HTTP 404)",
      "gh: Resource not accessible by integration (HTTP 403)",
      "gh: API rate limit exceeded for installation (HTTP 403)",
      "gh: Validation Failed (HTTP 422)",
      "unknown flag: --nope"
    ].each do |message|
      run = run_retrying("check", "--pr", "1490", failures: { "/pulls/1490/files" => [ message ] }, files: { 1490 => CLEAN_ROW })
      assert_not_predicate run.status, :success?, message
      assert_empty run.slept, message
      assert_equal 1, run.calls_matching("/pulls/1490/files").size, message
    end
  end

  test "the writes whose repeat changes nothing are retried" do
    run = run_retrying("sweep", failures: { "/statuses/aaaa1484" => [ SERVER_ERROR ], "pr edit" => [ SERVER_ERROR ] },
      prs: prs_json([ 1484, "aaaa1484", [ "ready to merge" ] ]), files: { 1484 => COLLIDING_ROW })

    assert_predicate run.status, :success?, run.output
    assert_includes run.posted, "state=failure"
    assert_includes run.edits, "--remove-label ready to merge"
  end

  # A 5xx can arrive after the write landed, so a repeat could post the comment or
  # start the CI run twice. The failure still reaches the job's exit status.
  test "the CI re-run and the comment get one attempt each, and a failure there fails the sweep" do
    [ "run rerun", "pr comment" ].each do |write|
      run = run_retrying("sweep", failures: { write => [ SERVER_ERROR ] },
        prs: prs_json([ 1484, "aaaa1484", [ "ready to merge" ] ]), files: { 1484 => COLLIDING_ROW })

      assert_not_predicate run.status, :success?, write
      assert_includes run.output, "Could not check #1484"
      assert_equal 1, run.calls_matching(write).size, write
      assert_empty run.slept, write
    end
  end

  # Enough failing PRs to outlast the job timeout if each took its full backoff.
  test "an outage across many PRs stops retrying at the window, and still asks about every PR" do
    numbers = (1..12).to_a
    run = run_retrying("sweep", failures: { "/files" => [ SERVER_ERROR ] * 1000 },
      prs: prs_json(*numbers.map { |number| [ number, "aaaa0000", [] ] }), files: {})

    assert_not_predicate run.status, :success?
    assert_operator run.slept.sum, :<=, 300
    assert_includes run.output, "retry window spent"
    numbers.each { |number| assert_not_empty run.calls_matching("/pulls/#{number}/files"), "##{number} was never asked about" }
    assert_includes run.output, "Could not check #{numbers.map { |number| "##{number}" }.join(", ")}"
  end

  test "sweep --dry-run posts nothing" do
    output, status, posted, edits = run_script("sweep", "--main-ref", "HEAD", "--dry-run",
      prs: prs_json([ 1484, "aaaa1484", [ "ready to merge" ] ]),
      files: { 1484 => "added\tdb/migrate/20261111120000_create_x.rb\t\n" })

    assert_predicate status, :success?, output
    assert_includes output, "#1484 aaaa1484: failure"
    assert_equal "", posted
    assert_equal "", edits
  end

  private

  SERVER_ERROR = "gh: Server Error: Sorry, this diff is temporarily unavailable due to heavy server load. (HTTP 500)"
  CLEAN_ROW = "added\tdb/migrate/20261114000000_add_doodad.rb\t\n"
  COLLIDING_ROW = "added\tdb/migrate/20261111120000_create_x.rb\t\n"

  RetryRun = Data.define(:output, :status, :posted, :edits, :slept, :calls) do
    def calls_matching(text) = calls.select { |call| call.include?(text) }
  end

  # `failures` maps a substring of a `gh` command line to the failures it gives,
  # in order, before it starts answering; each is a stderr message, or [stdout,
  # stderr message].
  #
  # Sleeps are recorded rather than slept, and move the monotonic clock the script
  # reads, so a run that would take minutes takes none.
  def run_retrying(command, *args, failures:, files:, prs: "")
    Dir.mktmpdir do |dir|
      slept = File.join(dir, "slept.txt")
      calls = File.join(dir, "calls.txt")
      FileUtils.touch([ slept, calls ])
      clock = File.join(dir, "fake_clock.rb")
      File.write(clock, <<~RUBY)
        module FakeClock
          @slept = 0
          class << self
            attr_accessor :slept
          end
        end
        module Kernel
          def sleep(seconds)
            FakeClock.slept += seconds
            File.write(#{slept.inspect}, "\#{seconds}\n", mode: "a")
          end
        end
        Process.singleton_class.prepend(Module.new do
          def clock_gettime(*args) = super + FakeClock.slept
        end)
      RUBY

      output, status, posted, edits = run_script(command, *args, "--main-ref", "HEAD", files: files, prs: prs,
        ruby_args: [ "-r", clock ], failures: failures, calls: calls)

      RetryRun.new(output:, status:, posted:, edits:,
        slept: File.readlines(slept, chomp: true).map(&:to_i), calls: File.readlines(calls, chomp: true))
    end
  end

  def prs_json(*prs)
    JSON.generate(prs.map do |number, sha, labels|
      { number: number, headRefOid: sha, labels: labels.map { |name| { name: name } } }
    end)
  end

  # Returns [combined output, process status, posted statuses, `gh pr edit` /
  # `gh pr comment` calls] — the last two one call per line.
  def run_script(*args, files:, prs: "", ruby_args: [], failures: {}, calls: File::NULL)
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      stubs = File.join(dir, "stubs")
      FileUtils.mkdir_p([ repo, stubs ])
      make_main(repo)

      files.each { |number, tsv| File.write(File.join(dir, "files-#{number}.tsv"), tsv) }
      File.write(File.join(dir, "prs.txt"), prs)
      posted = File.join(dir, "posted.txt")
      edits = File.join(dir, "edits.txt")
      FileUtils.touch([ posted, edits ])

      write_gh_stub(stubs, dir, posted, edits, calls)
      failures.each_with_index do |(match, messages), index|
        File.write(File.join(dir, "fail-#{index}.match"), match)
        messages.each_with_index do |message, attempt|
          stdout, stderr = message.is_a?(Array) ? message : [ "", message ]
          File.write(File.join(dir, "fail-#{index}.#{attempt}.out"), stdout)
          File.write(File.join(dir, "fail-#{index}.#{attempt}.err"), stderr)
        end
      end

      env = { "PATH" => "#{stubs}:#{ENV.fetch("PATH")}", "REPO" => "tadasant/zimmer" }
      output, status = Open3.capture2e(env, "ruby", *ruby_args, SCRIPT, *args, chdir: repo)

      [ output, status, File.read(posted), File.read(edits) ]
    end
  end

  def make_main(repo)
    MAIN.each do |path|
      FileUtils.mkdir_p(File.join(repo, File.dirname(path)))
      FileUtils.touch(File.join(repo, path))
    end
    git = ->(*args) { system("git", "-C", repo, *args, out: File::NULL, err: File::NULL) || flunk("git #{args.first} failed") }
    git.call("init", "-q")
    git.call("add", ".")
    git.call("-c", "user.name=t", "-c", "user.email=t@example.test", "commit", "-q", "-m", "main")
  end

  # `gh api …/pulls/N/files` prints files-N.tsv (or fails, if there is none);
  # `gh pr list` prints prs.txt; `gh run list --commit SHA` prints `run-SHA`;
  # `gh api -X POST …/statuses/SHA`, `gh pr edit|comment` and `gh run rerun`
  # record their arguments, newlines folded, one call per line.
  # Every call is recorded first, then checked against fail-*: a matching call uses
  # up the next failure listed for it, until there are none left.
  def write_gh_stub(stubs, dir, posted, edits, calls)
    path = File.join(stubs, "gh")
    File.write(path, <<~SH)
      #!/bin/bash
      line=$(printf '%s' "$*" | tr '\n' ' ')
      echo "$line" >> "#{calls}"
      for match in "#{dir}"/fail-*.match; do
        [ -f "$match" ] || continue
        case "$line" in *"$(cat "$match")"*) ;; *) continue ;; esac
        base="${match%.match}"; used=$(cat "$base.used" 2>/dev/null || echo 0)
        [ -f "$base.$used.err" ] || continue
        echo $((used + 1)) > "$base.used"
        cat "$base.$used.out"; cat "$base.$used.err" >&2; exit 1
      done
      if [ "$1 $2" = "pr list" ]; then cat "#{dir}/prs.txt"; exit 0; fi
      if [ "$1 $2" = "run list" ]; then
        while [ $# -gt 0 ]; do [ "$1" = "--commit" ] && { echo "run-$2"; exit 0; }; shift; done
        exit 1
      fi
      if [ "$1" = "pr" ] || [ "$1 $2" = "run rerun" ]; then printf '%s' "$*" | tr '\n' ' ' >> "#{edits}"; echo >> "#{edits}"; exit 0; fi
      if [ "$2" = "-X" ]; then echo "$*" >> "#{posted}"; exit 0; fi
      for arg in "$@"; do
        case "$arg" in
          */pulls/*/files)
            number="${arg%/files}"; number="${number##*/}"
            [ -f "#{dir}/files-$number.tsv" ] || { echo "HTTP 404" >&2; exit 1; }
            cat "#{dir}/files-$number.tsv"; exit 0 ;;
        esac
      done
      echo "unexpected gh call: $*" >&2; exit 1
    SH
    File.chmod(0o755, path)
  end
end
