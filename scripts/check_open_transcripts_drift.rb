#!/usr/bin/env ruby
# frozen_string_literal: true

# Fails when the vendored OpenTranscripts snapshot has drifted from upstream.
#
# `app/services/open_transcript.rb` is a hand-written mirror of the
# OpenTranscripts v0.1 spec in pulsemcp/ai-artifacts. Without this check the
# mirror rots quietly: upstream fixes — including security fixes to the
# reference redactor — never reach Zimmer and nobody finds out.
#
# Stdlib only, and no Rails boot: this runs on a schedule where a database and a
# loaded application would be pure cost. `vendor/open_transcripts/UPSTREAM.json`
# is the pin; every file listed there is re-fetched from the upstream branch and
# compared by SHA-256.
#
# Exit codes:
#   0  snapshot matches upstream
#   1  drift detected (or a listed file vanished upstream)
#   2  the check could not run (network/API failure) — distinct on purpose, so a
#      GitHub outage does not read as "upstream changed"
#
# See vendor/open_transcripts/README.md for how to refresh the snapshot.

require "digest"
require "json"
require "net/http"
require "uri"

ROOT = File.expand_path("..", __dir__)
VENDOR_DIR = File.join(ROOT, "vendor", "open_transcripts")
MANIFEST_PATH = File.join(VENDOR_DIR, "UPSTREAM.json")

EXIT_OK = 0
EXIT_DRIFT = 1
EXIT_UNAVAILABLE = 2

def abort_unavailable(message)
  warn "::error::OpenTranscripts drift check could not run: #{message}"
  exit EXIT_UNAVAILABLE
end

# Read one upstream file. Returns [:ok, body] / [:missing, nil] / [:error, reason].
#
# OPEN_TRANSCRIPTS_SOURCE_DIR swaps GitHub for a local directory laid out with the
# same upstream paths. It exists so the comparison and exit codes can be tested
# offline (test/scripts/check_open_transcripts_drift_test.rb) — a drift check whose
# own failure path is unproven is not much of a guard.
def read_upstream(repository, branch, path)
  local_root = ENV["OPEN_TRANSCRIPTS_SOURCE_DIR"].to_s
  return read_local(File.join(local_root, path)) unless local_root.empty?

  fetch("https://raw.githubusercontent.com/#{repository}/#{branch}/#{path}")
end

def read_local(path)
  return [ :missing, nil ] unless File.exist?(path)

  [ :ok, File.binread(path) ]
rescue StandardError => e
  [ :error, "#{e.class}: #{e.message}" ]
end

def fetch(url)
  uri = URI.parse(url)
  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = "zimmer-open-transcripts-drift-check"
  # Deliberately unauthenticated. raw.githubusercontent.com serves public content
  # from a CDN with no rate limit worth working around, and a token scoped to a
  # DIFFERENT repository answers 404 rather than 200 — which this script would
  # then report as "upstream deleted the file". No credential is the correct
  # credential here.

  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 15, read_timeout: 30) do |http|
    http.request(request)
  end

  case response
  when Net::HTTPSuccess then [ :ok, response.body ]
  when Net::HTTPNotFound then [ :missing, nil ]
  else [ :error, "#{response.code} #{response.message}" ]
  end
rescue StandardError => e
  [ :error, "#{e.class}: #{e.message}" ]
end

manifest_path = ENV.fetch("OPEN_TRANSCRIPTS_MANIFEST", MANIFEST_PATH)

manifest = begin
  JSON.parse(File.read(manifest_path))
rescue Errno::ENOENT, JSON::ParserError => e
  abort_unavailable("#{manifest_path} is missing or unreadable (#{e.class})")
end

repository = manifest.fetch("repository")
branch = manifest.fetch("branch")
files = manifest.fetch("files")

puts "Checking #{files.length} vendored OpenTranscripts file(s) against #{repository}@#{branch}"
puts "Snapshot pinned at #{manifest['ref']} (captured #{manifest['captured_at']})"
puts

drifted = []
missing = []

files.each do |entry|
  local = entry.fetch("local")
  upstream = entry.fetch("upstream")
  expected = entry.fetch("sha256")

  status, body = read_upstream(repository, branch, upstream)

  case status
  when :error
    abort_unavailable("fetching #{upstream} failed (#{body})")
  when :missing
    missing << upstream
    puts "GONE   #{local} — #{upstream} no longer exists upstream"
    next
  end

  actual = Digest::SHA256.hexdigest(body)
  if actual == expected
    puts "OK     #{local}"
  else
    drifted << { local: local, upstream: upstream, expected: expected, actual: actual }
    puts "DRIFT  #{local} — expected #{expected[0, 12]}…, upstream is #{actual[0, 12]}…"
  end
end

if drifted.empty? && missing.empty?
  puts
  puts "No drift: the vendored snapshot matches #{repository}@#{branch}."
  exit EXIT_OK
end

puts
warn "::error::The vendored OpenTranscripts snapshot has drifted from #{repository}@#{branch}."
missing.each { |path| warn "::error::Upstream file removed: #{path}" }
drifted.each { |entry| warn "::error::Upstream file changed: #{entry[:upstream]} (vendored as #{entry[:local]})" }
warn ""
warn "This is not automatically a bug in Zimmer — upstream may have changed something Zimmer"
warn "does not mirror. It IS a decision someone has to make, which is the point of this check."
warn "Refresh the snapshot and reconcile app/services/open_transcript.rb and"
warn "app/services/transcript_redactor.rb: see vendor/open_transcripts/README.md."
exit EXIT_DRIFT
