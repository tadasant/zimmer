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

  def prs_json(*prs)
    JSON.generate(prs.map do |number, sha, labels|
      { number: number, headRefOid: sha, labels: labels.map { |name| { name: name } } }
    end)
  end

  # Returns [combined output, process status, posted statuses, `gh pr edit` /
  # `gh pr comment` calls] — the last two one call per line.
  def run_script(*args, files:, prs: "")
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

      write_gh_stub(stubs, dir, posted, edits)

      env = { "PATH" => "#{stubs}:#{ENV.fetch("PATH")}", "REPO" => "tadasant/zimmer" }
      output, status = Open3.capture2e(env, "ruby", SCRIPT, *args, chdir: repo)

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
  def write_gh_stub(stubs, dir, posted, edits)
    path = File.join(stubs, "gh")
    File.write(path, <<~SH)
      #!/bin/bash
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
