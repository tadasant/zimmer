# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# Drives the staging workflows' tailnet join with `curl` and `tailscale` stubbed on PATH.
#
# The join broke silently once already (run 44922555470): the static TS_CI_AUTHKEY expired,
# every `tailscale up` was rejected, the action stayed green, and the job died ten minutes
# later blaming the droplet. These cases pin the two halves of the fix: the mint prefers the
# OAuth client and says so loudly when it has to fall back, and the verify step fails with
# the runner's real state rather than letting a NeedsLogin runner carry on.
class TailnetJoinTest < ActiveSupport::TestCase
  MINT = Rails.root.join(".github/scripts/tailnet-authkey.sh")
  VERIFY = Rails.root.join(".github/scripts/tailnet-verify-joined.sh")

  def write_bin(dir, name, body)
    path = File.join(dir, name)
    File.write(path, "#!/bin/bash\n#{body}\n")
    File.chmod(0o755, path)
  end

  # A curl stub that answers the token exchange and the key mint from canned JSON, writing to
  # whatever `-o` names and printing the status for `-w`. It records each URL and its stdin.
  CURL = <<~'SH'
    out=""; url=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) out="$2"; shift 2 ;;
        -w|-H|--data-urlencode|--data-binary|--max-time|--retry) shift 2 ;;
        -K|-sS) shift ;;
        *) url="$1"; shift ;;
      esac
    done
    stdin=$(cat)
    printf '%s\t%s\n' "$url" "$stdin" >> "$LOG"
    case "$url" in
      */oauth/token) printf '%s' "$TOKEN_BODY" > "$out"; printf '%s' "$TOKEN_CODE" ;;
      */keys)        printf '%s' "$KEY_BODY" > "$out";   printf '%s' "$KEY_CODE" ;;
    esac
  SH

  def run_mint(env)
    Dir.mktmpdir do |dir|
      write_bin(dir, "curl", CURL)
      log = File.join(dir, "calls")
      out = File.join(dir, "authkey")
      base = {
        "PATH" => "#{dir}:#{ENV['PATH']}", "LOG" => log,
        "TS_OAUTH_CLIENT_ID" => "client-id", "TS_OAUTH_CLIENT_SECRET" => "tskey-client-SECRET",
        "TS_FALLBACK_AUTHKEY" => "",
        "TOKEN_CODE" => "200", "TOKEN_BODY" => '{"access_token":"bearer-TOKEN"}',
        "KEY_CODE" => "200", "KEY_BODY" => '{"key":"tskey-auth-MINTED"}'
      }
      stdout, stderr, status = Open3.capture3(base.merge(env), "bash", MINT.to_s, out)
      key = File.exist?(out) ? File.read(out).strip : nil
      mode = File.exist?(out) ? File.stat(out).mode & 0o777 : nil
      calls = File.exist?(log) ? File.read(log) : ""
      yield status.exitstatus, stdout + stderr, key, mode, calls
    end
  end

  test "mints a tag:zimmer-ci key from the OAuth client and writes it 0600" do
    run_mint({}) do |code, out, key, mode, calls|
      assert_equal 0, code, out
      assert_equal "tskey-auth-MINTED", key
      assert_equal 0o600, mode
      assert_match(/minted via OAuth \(tags=tag:zimmer-ci/, out)
      assert_includes out, "::add-mask::tskey-auth-MINTED"
      refute_match(/::warning/, out)
      # The client secret and bearer travel on stdin, never argv.
      assert_match(%r{oauth/token\ttskey-client-SECRET}, calls)
      assert_match(%r{/keys\theader = "Authorization: Bearer bearer-TOKEN"}, calls)
    end
  end

  test "a rejected token exchange falls back to TS_CI_AUTHKEY with a warning naming the fix" do
    env = { "TOKEN_CODE" => "401", "TOKEN_BODY" => '{"message":"invalid client"}', "TS_FALLBACK_AUTHKEY" => "tskey-auth-STATIC" }
    run_mint(env) do |code, out, key, _mode, _calls|
      assert_equal 0, code, out
      assert_equal "tskey-auth-STATIC", key
      assert_match(/::warning title=tailnet auth key: OAuth mint failed.*HTTP 401 \(invalid client\)/, out)
      assert_includes out, "TS_CI_OAUTH_CLIENT_ID"
    end
  end

  test "a mint the client is not allowed to make names the tag it needs" do
    env = { "KEY_CODE" => "403", "KEY_BODY" => '{"message":"requested tags are invalid or not permitted"}' }
    run_mint(env) do |code, out, key, _mode, _calls|
      assert_equal 1, code, out
      assert_nil key
      assert_match(/::error title=tailnet auth key: no usable credential::.*HTTP 403.*own tags \[tag:zimmer-ci\]/, out)
    end
  end

  test "no OAuth client and no fallback fails the step instead of joining nothing" do
    run_mint({ "TS_OAUTH_CLIENT_ID" => "", "TS_OAUTH_CLIENT_SECRET" => "" }) do |code, out, key, _mode, calls|
      assert_equal 1, code, out
      assert_nil key
      assert_empty calls, "no credential means no API call"
      assert_match(/::error title=tailnet auth key: no usable credential::no OAuth client is configured/, out)
    end
  end

  def run_verify(status_json)
    Dir.mktmpdir do |dir|
      write_bin(dir, "tailscale", <<~SH)
        if [ "$1" = status ] && [ "$2" = "--json" ]; then printf '%s' "$STATUS_JSON"; else echo "Logged out."; fi
      SH
      write_bin(dir, "sleep", "exit 0")
      env = { "PATH" => "#{dir}:#{ENV['PATH']}", "STATUS_JSON" => status_json, "TS_VERIFY_ATTEMPTS" => "3" }
      stdout, stderr, status = Open3.capture3(env, "bash", VERIFY.to_s)
      yield status.exitstatus, stdout + stderr
    end
  end

  test "a runner whose key was rejected fails loudly, blaming the runner and not the droplet" do
    run_verify('{"BackendState":"NeedsLogin"}') do |code, out|
      assert_equal 1, code, out
      assert_match(/::error title=Runner is not on the tailnet::the runner never authenticated/, out)
      assert_includes out, "The droplet is not the problem"
    end
  end

  test "a running runner passes and reports its identity" do
    json = '{"BackendState":"Running","Self":{"HostName":"github-runner","TailscaleIPs":["100.64.0.9"],"Tags":["tag:zimmer-ci"]}}'
    run_verify(json) do |code, out|
      assert_equal 0, code, out
      assert_match(/runner is on the tailnet: github-runner 100\.64\.0\.9 tags=tag:zimmer-ci/, out)
    end
  end

  test "both staging workflows join through the minted key, never the static secret directly" do
    %w[deploy-staging.yml domain-cert-staging.yml].each do |wf|
      text = Rails.root.join(".github/workflows", wf).read
      refute_match(/authkey:\s*\$\{\{\s*secrets\.TS_CI_AUTHKEY/, text, "#{wf} hands the static key to the action")
      assert_includes text, "authkey: file:${{ runner.temp }}/tailnet-authkey", wf
      assert_includes text, "tailnet-verify-joined.sh", wf
    end
  end
end
