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
# A droplet without Tailscale is named by CERT_HOST_IP instead: the script SSHes there with
# CERT_SSH_KEY, never touches DNS (the edge's tunnel owns the name), and runs the final probe ON
# the box, because the runner can reach only :22.
#
# `tailscale`, `ssh`, `curl` and the cert read are stubbed; the box holds a valid cert, so no
# issuance runs.
class DomainCertDnsTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("scripts", "domain-cert.sh")
  DOMAIN = "zimmer.example.com"
  TS_IP = "100.101.102.103"

  HOST_IP = "203.0.113.7"

  TAILSCALE_STUB = <<~SH
    printf '%s\\n' "$*" >> "$TAILSCALE_LOG"
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

  # Every call is logged. The cert read answers with a valid Let's Encrypt cert; the on-box
  # probe answers ssl_verify_result 0.
  SSH_STUB = <<~SH
    printf '%s\\n' "$*" >> "$SSH_LOG"
    case "$*" in
      *"openssl x509"*) printf 'issuer=C=US, O=Let'"'"'s Encrypt, CN=R11\\nsubject=CN=#{DOMAIN}\\n    DNS:#{DOMAIN}\\nrc=0\\n' ;;
      *"/up"*) echo 0 ;;
    esac
  SH

  def setup
    @dir = Dir.mktmpdir("domain-cert")
    @bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(@bin)
    { "tailscale" => TAILSCALE_STUB, "curl" => CURL_STUB, "ssh" => SSH_STUB }.each do |name, body|
      File.write(File.join(@bin, name), "#!/usr/bin/env bash\n#{body}\n")
      File.chmod(0o755, File.join(@bin, name))
    end
  end

  def teardown = FileUtils.rm_rf(@dir)

  def run_script(cname_records, env_overrides = {})
    File.write(File.join(@dir, "cname.json"), { result: cname_records }.to_json)
    env = {
      "PATH" => "#{@bin}:#{ENV.fetch('PATH')}",
      "CURL_LOG" => log_path("curl"), "SSH_LOG" => log_path("ssh"), "TAILSCALE_LOG" => log_path("tailscale"),
      "CNAME_JSON" => File.join(@dir, "cname.json"),
      "DOMAIN" => DOMAIN, "TS_HOST" => "zimmer", "CF_ZONE_ID" => "zone",
      "CF_API_TOKEN" => "cf-token", "ACME_EMAIL" => "ops@example.com",
      "CERT_SSH_KEY" => nil, "CERT_HOST_IP" => nil, "CERT_KNOWN_HOSTS" => nil, "FORCE_ISSUE" => nil
    }.merge(env_overrides)
    out, status = Open3.capture2e(env, "bash", SCRIPT.to_s)
    [ out, status, read_log("curl") ]
  end

  def log_path(name) = File.join(@dir, "#{name}.log")
  def read_log(name) = File.exist?(log_path(name)) ? File.readlines(log_path(name), chomp: true) : []

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

  test "CERT_HOST_IP reaches the box over key SSH with no tailnet and no DNS writes" do
    out, status, calls = run_script([], "TS_HOST" => nil, "CERT_HOST_IP" => HOST_IP, "CERT_SSH_KEY" => "/tmp/key")

    assert status.success?, out
    assert_empty read_log("tailscale"), "no-Tailscale mode invoked tailscale"
    assert_empty calls.grep(/dns_records/), "no-Tailscale mode touched DNS:\n#{calls.join("\n")}"
    assert_match(/leaving DNS for #{Regexp.escape(DOMAIN)} alone/, out)

    ssh = read_log("ssh")
    refute_empty ssh, "nothing was SSHed"
    assert ssh.all? { _1.include?("-i /tmp/key") && _1.include?("root@#{HOST_IP}") },
      "every SSH must use CERT_SSH_KEY against CERT_HOST_IP:\n#{ssh.join("\n")}"
  end

  test "with CERT_HOST_IP the final probe runs on the box, against its own Caddy" do
    out, status, calls = run_script([], "TS_HOST" => nil, "CERT_HOST_IP" => HOST_IP, "CERT_SSH_KEY" => "/tmp/key")

    assert status.success?, out
    assert_empty calls.grep(%r{/up}), "the runner probed :443 itself, which its :22-only rule cannot reach"
    probe = read_log("ssh").grep(%r{https://#{Regexp.escape(DOMAIN)}/up}).first
    assert probe, "no on-box probe ran:\n#{read_log('ssh').join("\n")}"
    assert_includes probe, "--resolve '#{DOMAIN}:443:127.0.0.1'"
  end

  test "CERT_HOST_IP without CERT_SSH_KEY fails before touching anything" do
    out, status, calls = run_script([], "TS_HOST" => nil, "CERT_HOST_IP" => HOST_IP)

    refute status.success?
    assert_match(/CERT_HOST_IP needs CERT_SSH_KEY/, out)
    assert_empty calls
    assert_empty read_log("ssh")
  end

  test "neither TS_HOST nor CERT_HOST_IP is an error that names both" do
    out, status, = run_script([], "TS_HOST" => nil)

    refute status.success?
    assert_match(/TS_HOST.*CERT_HOST_IP/, out)
  end

  test "CERT_HOST_IP wins over TS_HOST, so the tailnet is never consulted" do
    out, status, = run_script([], "CERT_HOST_IP" => HOST_IP, "CERT_SSH_KEY" => "/tmp/key")

    assert status.success?, out
    assert_empty read_log("tailscale")
    assert read_log("ssh").all? { _1.include?("root@#{HOST_IP}") }
  end

  test "CERT_KNOWN_HOSTS makes SSH verify the host key; without it the first key is accepted" do
    _, status, = run_script([], "TS_HOST" => nil, "CERT_HOST_IP" => HOST_IP, "CERT_SSH_KEY" => "/tmp/key",
      "CERT_KNOWN_HOSTS" => "/tmp/known_hosts")
    assert status.success?
    assert read_log("ssh").all? { _1.include?("StrictHostKeyChecking=yes") && _1.include?("UserKnownHostsFile=/tmp/known_hosts") }

    File.delete(log_path("ssh"))
    run_script([], "TS_HOST" => nil, "CERT_HOST_IP" => HOST_IP, "CERT_SSH_KEY" => "/tmp/key")
    assert read_log("ssh").all? { _1.include?("StrictHostKeyChecking=accept-new") }
  end
end
