# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# scripts/domain-cert.sh upserts `domain -> tailnet IP` as an A record -- unless the domain is
# served by the optional Cloudflare edge, whose tunnel owns the name as a proxied CNAME to
# <tunnel-id>.cfargotunnel.com. There the upsert would fail every week (a name cannot carry an A
# record and a CNAME), so the LIVE record decides and the script leaves DNS alone.
#
# Its final probe must test this box's Caddy, not whatever public DNS points at: it pins the name
# to the tailnet IP with --resolve, so after cutover it does not end up probing Cloudflare.
#
# `tailscale`, `curl` and the cert read are stubbed; the box holds a valid cert, so no issuance runs.
class DomainCertDnsTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("scripts", "domain-cert.sh")
  DOMAIN = "zimmer.example.com"
  TS_IP = "100.101.102.103"

  TAILSCALE_STUB = <<~SH
    case "$1" in
      status) echo '{"Peer":{"n1":{"HostName":"zimmer","Online":true,"TailscaleIPs":["#{TS_IP}"]}}}' ;;
      ssh) printf 'issuer=C=US, O=Let'"'"'s Encrypt, CN=R11\\nsubject=CN=#{DOMAIN}\\n    DNS:#{DOMAIN}\\nrc=0\\n' ;;
    esac
  SH

  # Cloudflare API calls answer from $CNAME_JSON (type=CNAME lookups) or an empty result; the
  # health probe answers ssl_verify_result 0. Every call is logged.
  CURL_STUB = <<~SH
    printf '%s\\n' "$*" >> "$CURL_LOG"
    case "$*" in
      *"type=CNAME"*) cat "$CNAME_JSON" ;;
      *api.cloudflare.com*) echo '{"result":[]}' ;;
      */up*) echo 0 ;;
    esac
  SH

  def setup
    @dir = Dir.mktmpdir("domain-cert")
    @bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(@bin)
    { "tailscale" => TAILSCALE_STUB, "curl" => CURL_STUB }.each do |name, body|
      File.write(File.join(@bin, name), "#!/usr/bin/env bash\n#{body}\n")
      File.chmod(0o755, File.join(@bin, name))
    end
  end

  def teardown = FileUtils.rm_rf(@dir)

  def run_script(cname_records)
    File.write(File.join(@dir, "cname.json"), { result: cname_records }.to_json)
    env = {
      "PATH" => "#{@bin}:#{ENV.fetch('PATH')}",
      "CURL_LOG" => File.join(@dir, "curl.log"),
      "CNAME_JSON" => File.join(@dir, "cname.json"),
      "DOMAIN" => DOMAIN, "TS_HOST" => "zimmer", "CF_ZONE_ID" => "zone",
      "CF_API_TOKEN" => "cf-token", "ACME_EMAIL" => "ops@example.com",
      "CERT_SSH_KEY" => nil, "FORCE_ISSUE" => nil
    }
    out, status = Open3.capture2e(env, "bash", SCRIPT.to_s)
    [ out, status, File.readlines(File.join(@dir, "curl.log"), chomp: true) ]
  end

  def writes(calls) = calls.grep(/-X (POST|PUT) .*dns_records/)

  test "a tailnet domain gets its A record upserted, as before" do
    out, status, calls = run_script([])

    assert status.success?, out
    assert_equal 1, writes(calls).size, "expected one A-record write:\n#{calls.join("\n")}"
    assert_match(/created A record #{Regexp.escape(DOMAIN)} -> #{TS_IP}/, out)
  end

  test "a domain the Cloudflare Tunnel owns is left alone" do
    out, status, calls = run_script([ { type: "CNAME", name: DOMAIN, content: "6ff42ae2-765d-4adf-8112-31c55c1551ef.cfargotunnel.com" } ])

    assert status.success?, out
    assert_empty writes(calls), "the script wrote DNS over the tunnel's CNAME:\n#{calls.join("\n")}"
    assert_match(/Cloudflare Tunnel CNAME/, out)
  end

  test "a CNAME that is not a tunnel does not stop the upsert" do
    out, status, calls = run_script([ { type: "CNAME", name: DOMAIN, content: "elsewhere.example.net" } ])

    assert status.success?, out
    assert_equal 1, writes(calls).size
  end

  test "the final probe is pinned to the box, not to public DNS" do
    out, status, calls = run_script([ { type: "CNAME", name: DOMAIN, content: "x.cfargotunnel.com" } ])

    assert status.success?, out
    probe = calls.grep(%r{https://#{Regexp.escape(DOMAIN)}/up}).first
    assert probe, "no health probe ran:\n#{calls.join("\n")}"
    assert_includes probe, "--resolve #{DOMAIN}:443:#{TS_IP}"
  end
end
