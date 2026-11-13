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
# and only that. So a colliding PR that carries the `ready to merge` label — the
# label the merge gate keys on — also loses it, with a comment saying why. The
# session holding the PR is woken by the label coming off.
#
# REPO (owner/name) must be set; `gh` must be authenticated. Rails-free: the
# comparison is MigrationVersionGuard.merge_collisions, the inputs are `git
# ls-tree` and the PR files API.
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
    when "check" then check(pr: options.fetch(:pr), main_ref: options.fetch(:main_ref))
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

    open_pull_requests.each do |number, head_sha, labels|
      changes = migration_changes(number)
      # A PR that adds no migration cannot collide, and stays without the
      # status rather than collecting a green one it has no use for.
      next if changes[:added].empty?

      collisions = MigrationVersionGuard.merge_collisions(main: main, **changes)
      state, description = collisions.empty? ? [ "success", "No migration version or name collides with main." ] : [ "failure", summary(collisions) ]
      puts "##{number} #{head_sha[0, 12]}: #{state} — #{description}"
      next if dry_run

      post_status(head_sha, state, description, target_url)
      unlabel(number, collisions, target_url) if state == "failure" && labels.include?(READY_LABEL)
    end
  end

  # Paths relative to db/migrate, which is what the guard compares.
  def main_paths(ref)
    git("ls-tree", "-r", "--name-only", ref, "--", MIGRATE_PREFIX).lines(chomp: true)
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

  # [number, head sha, label names]. Tab-separated because label names have
  # spaces in them.
  def open_pull_requests
    gh("pr", "list", "--repo", repo, "--base", "main", "--state", "open", "--limit", "1000",
      "--json", "number,headRefOid,labels",
      "--jq", '.[] | [(.number | tostring), .headRefOid, ([.labels[].name] | join(","))] | @tsv')
      .lines(chomp: true).map do |row|
        number, sha, labels = row.split("\t", 3)
        [ number, sha, labels.to_s.split(",") ]
      end
  end

  def unlabel(number, collisions, target_url)
    gh("pr", "edit", number.to_s, "--repo", repo, "--remove-label", READY_LABEL)
    gh("pr", "comment", number.to_s, "--repo", repo, "--body", <<~BODY)
      `main` gained a migration that collides with one this PR adds, so this PR would
      break `main` if it merged now. `#{READY_LABEL}` is removed until it is fixed.

      ```
      #{MigrationVersionGuard.report(collisions).strip}
      ```

      Renumber this PR's migration and push; the `lint` job checks it against current
      `main` again. Found by #{target_url || "the migration-versions-vs-main workflow"}.
    BODY
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

  # Fail loudly: a check that could not read its inputs has not passed.
  def run_command(*command)
    output, error, status = Open3.capture3(*command)
    abort "#{command.first(3).join(" ")} … failed (#{status.exitstatus}):\n#{error}" unless status.success?

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
