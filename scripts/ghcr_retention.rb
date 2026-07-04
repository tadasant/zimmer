#!/usr/bin/env ruby
# frozen_string_literal: true

# GHCR retention selector for ghcr.io/tadasant/zimmer.
#
# Keeps at most RETENTION_LIMIT (default 50) container versions, choosing which
# to KEEP with this priority order (higher tiers are protected first, so when the
# cap forces a trade-off the lower tiers are pruned first):
#
#   Tier 1  latest version within each MAJOR
#   Tier 2  latest version within each MINOR (major.minor)
#   Tier 3  latest 20 PATCH releases within the latest major.minor line
#   Tier 4  a ~modulo-10 cadence across the remaining older versions,
#           favoring more recent ones (fills whatever slots remain up to the cap)
#
# Everything not selected to keep is pruned. The selection logic is pure and unit
# tested (see scripts/ghcr_retention_test.rb); the GitHub API glue at the bottom
# is only exercised when run as a CLI with a token.
#
# Usage (dry run):   ruby scripts/ghcr_retention.rb --dry-run
# Usage (prune):     GITHUB_TOKEN=... ruby scripts/ghcr_retention.rb --prune
#
# Env:
#   GITHUB_TOKEN         token with delete:packages (and read:packages) scope
#   GHCR_OWNER           default "tadasant"
#   GHCR_PACKAGE         default "zimmer"
#   GHCR_OWNER_TYPE      "users" (default) or "orgs"
#   RETENTION_LIMIT      default 50

module GhcrRetention
  DEFAULT_LIMIT = 50
  LATEST_PATCHES_IN_LEAD_LINE = 20
  CADENCE = 10

  Version = Struct.new(:raw, :major, :minor, :patch, :id) do
    def line = [major, minor]
    def <=>(other) = [major, minor, patch] <=> [other.major, other.minor, other.patch]
    include Comparable
  end

  module_function

  # Parse "v1.2.3" / "1.2.3" / "1.2.3-rc1" (build/prerelease suffix ignored for
  # ordering). Returns nil for non-semver tags (e.g. "latest", "sha-abc123") so
  # they are ignored by the selector and never counted toward the cap.
  def parse(raw, id: nil)
    m = raw.to_s.strip.match(/\Av?(\d+)\.(\d+)\.(\d+)/)
    return nil unless m

    Version.new(raw, m[1].to_i, m[2].to_i, m[3].to_i, id)
  end

  # Accepts an array of raw tag strings OR pre-parsed Version structs.
  # Returns the Versions to KEEP, in priority order, capped at `limit`.
  def select_to_keep(versions, limit: DEFAULT_LIMIT)
    parsed = versions.map { |v| v.is_a?(Version) ? v : parse(v) }.compact
    return [] if parsed.empty?

    # Newest first, de-duplicated by (major,minor,patch).
    sorted = parsed.sort.reverse.uniq { |v| [v.major, v.minor, v.patch] }

    keep = []
    add = ->(v) { keep << v unless keep.any? { |k| k.line == v.line && k.patch == v.patch } }

    # Tier 1: latest within each major.
    sorted.group_by(&:major).each_value { |vs| add.call(vs.max) }

    # Tier 2: latest within each minor.
    sorted.group_by(&:line).each_value { |vs| add.call(vs.max) }

    # Tier 3: latest N patches within the leading major.minor line.
    lead = sorted.first.line
    sorted.select { |v| v.line == lead }.first(LATEST_PATCHES_IN_LEAD_LINE).each { |v| add.call(v) }

    # Tier 4: modulo-cadence across remaining older versions, most-recent first.
    remaining = sorted.reject { |v| keep.include?(v) }
    remaining.each_with_index { |v, i| add.call(v) if (i % CADENCE).zero? }

    keep.uniq.first(limit)
  end

  # The complement: Versions to prune (everything parseable that isn't kept).
  # Non-semver tags are never returned (never pruned by this tool).
  def select_to_prune(versions, limit: DEFAULT_LIMIT)
    parsed = versions.map { |v| v.is_a?(Version) ? v : parse(v) }.compact
                     .uniq { |v| [v.major, v.minor, v.patch] }
    keep = select_to_keep(parsed, limit: limit)
    kept = keep.map { |v| [v.major, v.minor, v.patch] }.to_set
    parsed.reject { |v| kept.include?([v.major, v.minor, v.patch]) }
  end
end

require "set"

# ---- CLI / GitHub API glue (only runs when invoked directly) ----------------
if __FILE__ == $PROGRAM_NAME
  require "net/http"
  require "json"
  require "uri"

  owner = ENV.fetch("GHCR_OWNER", "tadasant")
  package = ENV.fetch("GHCR_PACKAGE", "zimmer")
  owner_type = ENV.fetch("GHCR_OWNER_TYPE", "users")
  limit = Integer(ENV.fetch("RETENTION_LIMIT", GhcrRetention::DEFAULT_LIMIT))
  dry_run = ARGV.include?("--dry-run") || !ARGV.include?("--prune")
  token = ENV["GITHUB_TOKEN"]
  abort "GITHUB_TOKEN required" if token.nil? || token.empty?

  base = "https://api.github.com/#{owner_type}/#{owner}/packages/container/#{package}/versions"

  def gh(uri, token, method: :get)
    req = (method == :delete ? Net::HTTP::Delete : Net::HTTP::Get).new(uri)
    req["Authorization"] = "Bearer #{token}"
    req["Accept"] = "application/vnd.github+json"
    req["X-GitHub-Api-Version"] = "2022-11-28"
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  end

  # Paginate all versions. Each version has an id and metadata.container.tags[].
  page = 1
  raw_versions = []
  loop do
    res = gh(URI("#{base}?per_page=100&page=#{page}"), token)
    abort "GitHub API error #{res.code}: #{res.body}" unless res.code.to_i == 200

    batch = JSON.parse(res.body)
    break if batch.empty?

    batch.each do |v|
      (v.dig("metadata", "container", "tags") || []).each do |tag|
        parsed = GhcrRetention.parse(tag, id: v["id"])
        raw_versions << parsed if parsed
      end
    end
    page += 1
  end

  prune = GhcrRetention.select_to_prune(raw_versions, limit: limit)
  keep = GhcrRetention.select_to_keep(raw_versions, limit: limit)

  puts "Parsed semver versions: #{raw_versions.uniq { |v| [v.major, v.minor, v.patch] }.size}"
  puts "Keeping #{keep.size}: #{keep.map(&:raw).join(', ')}"
  puts "Pruning #{prune.size}: #{prune.map(&:raw).join(', ')}"

  if dry_run
    puts "\n[dry-run] no deletions performed. Pass --prune to delete."
  else
    prune.each do |v|
      next if v.id.nil?

      res = gh(URI("#{base}/#{v.id}"), token, method: :delete)
      ok = [204, 200].include?(res.code.to_i)
      puts "  delete #{v.raw} (id=#{v.id}): #{ok ? 'ok' : "FAILED #{res.code}"}"
    end
  end
end
