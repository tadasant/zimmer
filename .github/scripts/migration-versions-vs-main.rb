#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the migrations a pull request adds against `main` as it is NOW, not as
# it was when the PR last ran CI.
#
#   migration-versions-vs-main.rb check --pr <number> --main-ref <ref>
#   migration-versions-vs-main.rb sweep --main-ref <ref> [--target-url <url>] [--dry-run]
#
# `check` is the `lint` job's step on a pull request: exit 1 with the report if
# merging the PR into <ref> would put two migrations on one version or one class
# name.
#
# `sweep` runs on every push to `main` that touches db/migrate. It asks the same
# question of every open PR that adds a migration and writes the answer to the
# PR's head commit as the `migration versions vs main` commit status. This is the
# half that closes zimmer#1500: #1484 last ran CI on 2026-11-11, #1483 merged the
# same version a day later, and nothing re-asked #1484 before it merged on the
# 13th. A sweep that fires when `main` moves is what re-asks.
#
# The status alone blocks nothing: the `main` ruleset requires `all-checks-pass`
# and only that. So for a colliding PR the sweep also re-runs its latest CI run,
# whose `lint` re-fetches `main` and goes red, taking `all-checks-pass` with it;
# and if the PR carries `ready to merge` — the label the merge gate keys on — it
# loses that too, with a comment saying why.
#
# One PR's failure does not stop the sweep: it is logged, the rest are still
# checked, and the job exits non-zero at the end.
#
# REPO (owner/name) must be set; `gh` must be authenticated. Rails-free: the
# comparison is MigrationVersionGuard.merge_collisions, the inputs are `git
# ls-tree` and the PR files API.
require "json"
require "open3"
require "optparse"
require_relative "../../test/support/migration_version_guard"

module MigrationVersionsVsMain
  MIGRATE_PREFIX = "db/migrate/"
  STATUS_CONTEXT = "migration versions vs main"
  READY_LABEL = "ready to merge"

  module_function

  def run(argv)
    command = argv.shift
    options = parse_options(argv)

    case command
    when "check"
      begin
        check(pr: options.fetch(:pr), main_ref: options.fetch(:main_ref))
      rescue CommandFailed => e
        abort e.message
      end
    when "sweep"
      sweep(main_ref: options.fetch(:main_ref), target_url: options[:target_url], dry_run: options[:dry_run])
    else abort "usage: #{File.basename($PROGRAM_NAME)} check --pr N --main-ref REF | sweep --main-ref REF"
    end
  end

  def check(pr:, main_ref:)
    collisions = collisions_for(pr, main_paths(main_ref))

    if collisions.empty?
      puts "PR ##{pr} adds no migration that collides with #{main_ref}."
      return
    end

    abort <<~MESSAGE
      Merging PR ##{pr} into #{main_ref} as it stands now would collide:

      #{MigrationVersionGuard.report(collisions)}
    MESSAGE
  end

  def sweep(main_ref:, target_url:, dry_run: false)
    main = main_paths(main_ref)

    failed = open_pull_requests.reject do |number, head_sha, labels|
      sweep_one(number, head_sha, labels, main: main, target_url: target_url, dry_run: dry_run)
      true
    rescue CommandFailed => e
      warn "##{number}: could not check — #{e.message}"
      false
    end

    abort "Could not check #{failed.map { |number, _| "##{number}" }.join(", ")}; see above." if failed.any?
  end

  def sweep_one(number, head_sha, labels, main:, target_url:, dry_run:)
    changes = migration_changes(number)
    # A PR that adds no migration cannot collide, and stays without the
    # status rather than collecting a green one it has no use for.
    return if changes[:added].empty?

    collisions = MigrationVersionGuard.merge_collisions(main: main, **changes)
    state, description = collisions.empty? ? [ "success", "No migration version or name collides with main." ] : [ "failure", summary(collisions) ]
    puts "##{number} #{head_sha[0, 12]}: #{state} — #{description}"
    return if dry_run

    post_status(head_sha, state, description, target_url)
    return if state == "success"

    rerun_ci(head_sha)
    unlabel(number, collisions, target_url) if labels.include?(READY_LABEL)
  end

  # Paths relative to db/migrate, which is what the guard compares.
  def main_paths(ref)
    # -z, because without it git quotes a path with unusual bytes in it.
    git("ls-tree", "-r", "-z", "--name-only", ref, "--", MIGRATE_PREFIX).split("\0")
      .map { |path| path.delete_prefix(MIGRATE_PREFIX) }
  end

  def collisions_for(pr, main)
    MigrationVersionGuard.merge_collisions(main: main, **migration_changes(pr))
  end

  # What the PR does to db/migrate, by the API's own account of it rather than a
  # diff against a merge base, so neither caller needs history in its checkout.
  # A rename removes the old path and adds the new one — renumbering a colliding
  # migration is a rename, and it has to clear the collision it fixes.
  def migration_changes(pr)
    added = []
    removed = []

    rows = gh("api", "--paginate", "repos/#{repo}/pulls/#{pr}/files",
      "--jq", '.[] | [.status, .filename, (.previous_filename // "")] | @tsv')
    rows.each_line(chomp: true) do |row|
      status, filename, previous = row.split("\t", 3)

      case status
      when "added", "copied" then added << filename
      when "removed" then removed << filename
      when "renamed"
        added << filename
        removed << previous
      end
    end

    {
      added: in_migrate_dir(added),
      removed: in_migrate_dir(removed)
    }
  end

  def in_migrate_dir(paths)
    paths.select { |path| path.start_with?(MIGRATE_PREFIX) }.map { |path| path.delete_prefix(MIGRATE_PREFIX) }
  end

  # [number, head sha, label names].
  def open_pull_requests
    JSON.parse(gh("pr", "list", "--repo", repo, "--base", "main", "--state", "open", "--limit", "1000",
      "--json", "number,headRefOid,labels")).map do |pr|
      [ pr.fetch("number"), pr.fetch("headRefOid"), pr.fetch("labels").map { |label| label.fetch("name") } ]
    end
  end

  # The PR's latest CI run, re-run in full. Its `lint` re-fetches `main`, so
  # it goes red, and `all-checks-pass` — the one check the ruleset requires —
  # with it. A run still in progress cannot be re-run; it is reading a `main`
  # fetched at its own start, which may predate this push, so that is reported
  # rather than ignored.
  def rerun_ci(head_sha)
    run_id = gh("run", "list", "--repo", repo, "--workflow", "ci.yml", "--commit", head_sha,
      "--event", "pull_request", "--limit", "1", "--json", "databaseId", "--jq", ".[0].databaseId // empty").strip
    return warn("  no CI run found for #{head_sha[0, 12]} to re-run") if run_id.empty?

    gh("run", "rerun", run_id, "--repo", repo)
  end

  # Comment first, so a run cancelled in between never leaves a label gone
  # with no word about why.
  def unlabel(number, collisions, target_url)
    gh("pr", "comment", number.to_s, "--repo", repo, "--body", <<~BODY)
      `main` gained a migration that collides with one this PR adds, so this PR would
      break `main` if it merged now. `#{READY_LABEL}` is removed until it is fixed.

      ```
      #{MigrationVersionGuard.report(collisions).strip}
      ```

      Renumber this PR's migration and push; the `lint` job checks it against current
      `main` again. Found by #{target_url || "the migration-versions-vs-main workflow"}.
    BODY
    gh("pr", "edit", number.to_s, "--repo", repo, "--remove-label", READY_LABEL)
  end

  # A commit status description is capped at 140 characters.
  def summary(collisions)
    text = collisions.map { |collision| "#{collision.value}: #{collision.paths.join(", ")}" }.join("; ")
    text = "Collides with main — #{text}"
    text.length > 140 ? "#{text[0, 139]}…" : text
  end

  def post_status(sha, state, description, target_url)
    args = [ "api", "-X", "POST", "repos/#{repo}/statuses/#{sha}",
      "-f", "state=#{state}", "-f", "context=#{STATUS_CONTEXT}", "-f", "description=#{description}" ]
    args += [ "-f", "target_url=#{target_url}" ] if target_url
    gh(*args)
  end

  def repo
    ENV.fetch("REPO")
  end

  def gh(*args)
    run_command("gh", *args)
  end

  def git(*args)
    run_command("git", *args)
  end

  class CommandFailed < StandardError; end

  # Fail loudly: a check that could not read its inputs has not passed. `check`
  # lets this escape and exits non-zero; `sweep` catches it per PR.
  def run_command(*command)
    output, error, status = Open3.capture3(*command)
    raise CommandFailed, "#{command.first(3).join(" ")} … failed (#{status.exitstatus}): #{error.strip}" unless status.success?

    output
  end

  def parse_options(argv)
    options = {}
    OptionParser.new do |parser|
      parser.on("--pr NUMBER", Integer) { |value| options[:pr] = value }
      parser.on("--main-ref REF") { |value| options[:main_ref] = value }
      parser.on("--target-url URL") { |value| options[:target_url] = value }
      parser.on("--dry-run") { options[:dry_run] = true }
    end.parse!(argv)
    options
  end
end

MigrationVersionsVsMain.run(ARGV) if $PROGRAM_NAME == __FILE__
