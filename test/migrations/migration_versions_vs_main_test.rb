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
      prs: "1484\taaaa1484\tready to merge,agent-filed\n1490\tbbbb1490\tready to merge\n1491\tcccc1491\t\n",
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
  test "sweep takes ready to merge off a colliding PR and says why" do
    output, status, _posted, edits = run_script("sweep", "--main-ref", "HEAD",
      prs: "1484\taaaa1484\tready to merge\n1490\tbbbb1490\tready to merge\n1492\tdddd1492\t\n",
      files: {
        1484 => "added\tdb/migrate/20261111120000_create_mcp_event_webhook_subscriptions.rb\t\n",
        1490 => "added\tdb/migrate/20261114000000_add_doodad.rb\t\n",
        1492 => "added\tdb/migrate/20261111120000_create_other.rb\t\n"
      })

    assert_predicate status, :success?, output
    edits = edits.lines(chomp: true)
    assert_includes edits, "pr edit 1484 --repo tadasant/zimmer --remove-label ready to merge"
    assert edits.any? { |line| line.start_with?("pr comment 1484") && line.include?("20261111120000") }, edits.inspect
    assert_not edits.any? { |line| line.include?(" 1490 ") }, "a clean PR lost its label"
    assert_not edits.any? { |line| line.include?(" 1492 ") }, "a colliding PR with no label to remove was commented on"
  end

  test "sweep --dry-run posts nothing" do
    output, status, posted, edits = run_script("sweep", "--main-ref", "HEAD", "--dry-run",
      prs: "1484\taaaa1484\tready to merge\n",
      files: { 1484 => "added\tdb/migrate/20261111120000_create_x.rb\t\n" })

    assert_predicate status, :success?, output
    assert_includes output, "#1484 aaaa1484: failure"
    assert_equal "", posted
    assert_equal "", edits
  end

  private

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
  # `gh pr list` prints prs.txt; `gh api -X POST …/statuses/SHA` and `gh pr
  # edit|comment` record their arguments, newlines folded, on one line.
  def write_gh_stub(stubs, dir, posted, edits)
    path = File.join(stubs, "gh")
    File.write(path, <<~SH)
      #!/bin/bash
      if [ "$1 $2" = "pr list" ]; then cat "#{dir}/prs.txt"; exit 0; fi
      if [ "$1" = "pr" ]; then printf '%s' "$*" | tr '\n' ' ' >> "#{edits}"; echo >> "#{edits}"; exit 0; fi
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
