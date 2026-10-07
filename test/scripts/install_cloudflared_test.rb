# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "digest"

# Drives scripts/install-cloudflared.sh against a fake host: `ssh` is stubbed on PATH and
# evaluates the remote command locally, `docker` records its argv and answers from a little
# state the test sets, and `install` writes without the chown a non-root test cannot do. So
# these assertions are about what the converge actually does to a host:
#
#   - an empty token touches nothing, and only an explicit opt-in removes a connector;
#   - a new token or image pulls BEFORE it removes, so a registry failure keeps the old one;
#   - a converged host is left alone (a restart would drop in-flight requests);
#   - the token reaches the host on stdin, into a file -- never on any command line;
#   - a connector that never registers fails the deploy.
class InstallCloudflaredTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("scripts", "install-cloudflared.sh")
  IMAGE = File.read(SCRIPT)[/^IMAGE="([^"]+)"$/, 1]
  # Shaped like a real token (base64 of a small JSON document); not one.
  TOKEN = Base64.strict_encode64({ a: "0" * 32, t: "11111111-2222-3333-4444-555555555555", s: "c2VjcmV0" }.to_json)

  SSH_STUB = <<~SH
    printf '%s\\t' "$@" >> "$ARGV_LOG"
    printf '\\n' >> "$ARGV_LOG"
    eval "${!#}"
  SH

  # State lives in files under $STATE: `spec` (label + running, or absent), `registered`.
  DOCKER_STUB = <<~SH
    printf 'docker %s\\n' "$*" >> "$DOCKER_LOG"
    case "$1" in
      inspect)
        [ -f "$STATE/spec" ] || exit 1
        case "$*" in
          *State.StartedAt*) echo 2026-10-07T21:47:35.123456789Z ;;
          *zimmer.cloudflared.spec*) cat "$STATE/spec" ;;
        esac ;;
      logs) [ -f "$STATE/registered" ] && echo 'INF Registered tunnel connection connIndex=0' ;;
      run) echo started > "$STATE/spec" ;;
      rm) rm -f "$STATE/spec" ;;
    esac
    exit 0
  SH

  # `install -d -m M DIR` or `install -m M -o U -g G SRC DEST`, minus the chown.
  INSTALL_STUB = <<~SH
    if [ "$1" = "-d" ]; then mkdir -p "${!#}"; exit 0; fi
    dest="${!#}"; set -- "${@:1:$(($# - 1))}"; cat "${!#}" > "$dest"
  SH

  def setup
    @dir = Dir.mktmpdir("install-cloudflared")
    @bin = File.join(@dir, "bin")
    @state = File.join(@dir, "state")
    @token_dir = File.join(@dir, "etc-zimmer", "cloudflared")
    FileUtils.mkdir_p([ @bin, @state ])
    { "ssh" => SSH_STUB, "docker" => DOCKER_STUB, "install" => INSTALL_STUB, "sleep" => "exit 0" }.each do |name, body|
      File.write(File.join(@bin, name), "#!/usr/bin/env bash\n#{body}\n")
      File.chmod(0o755, File.join(@bin, name))
    end
  end

  def teardown = FileUtils.rm_rf(@dir)

  def converge(env = {})
    full = {
      "PATH" => "#{@bin}:#{ENV.fetch('PATH')}",
      "ARGV_LOG" => File.join(@dir, "argv.log"),
      "DOCKER_LOG" => File.join(@dir, "docker.log"),
      "STATE" => @state,
      "ZIMMER_CLOUDFLARED_DIR" => @token_dir,
      "ZIMMER_CLOUDFLARED_WAIT" => "0",
      "CLOUDFLARE_TUNNEL_TOKEN" => nil,
      "ZIMMER_CLOUDFLARED_REMOVE" => nil,
      "ZIMMER_CLOUDFLARED_SSH_EXTRA" => nil
    }.merge(env)
    out, status = Open3.capture2e(full, "bash", SCRIPT.to_s, "box.example")
    [ out, status ]
  end

  def docker_calls = File.exist?(File.join(@dir, "docker.log")) ? File.readlines(File.join(@dir, "docker.log"), chomp: true) : []
  def ssh_argv = File.read(File.join(@dir, "argv.log"))
  def spec_for(token) = Digest::SHA256.hexdigest("#{IMAGE}\n#{token}\n")[0, 16]
  def running!(spec) = File.write(File.join(@state, "spec"), "#{spec} true")
  def registered! = File.write(File.join(@state, "registered"), "")

  test "an empty token changes nothing" do
    out, status = converge

    assert status.success?, out
    assert_match(/changing nothing/, out)
    assert_empty docker_calls.grep(/docker (pull|rm|run)/)
    refute File.exist?(@token_dir)
  end

  test "an empty token warns about, but keeps, a connector that is already running" do
    running!("whatever")
    out, status = converge

    assert status.success?, out
    assert_match(/::warning::zimmer-cloudflared is running/, out)
    assert_empty docker_calls.grep(/docker (rm|run)/)
  end

  test "an explicit remove takes the connector and its token down" do
    running!("whatever")
    FileUtils.mkdir_p(@token_dir)
    out, status = converge("ZIMMER_CLOUDFLARED_REMOVE" => "1")

    assert status.success?, out
    assert_includes docker_calls, "docker rm -f zimmer-cloudflared"
    refute File.exist?(@token_dir)
  end

  test "a fresh host pulls, then replaces, then runs the pinned connector" do
    registered!
    out, status = converge("CLOUDFLARE_TUNNEL_TOKEN" => TOKEN)

    assert status.success?, out
    calls = docker_calls
    pull = calls.index { _1.start_with?("docker pull") }
    rm = calls.index { _1.start_with?("docker rm") }
    run = calls.index { _1.start_with?("docker run") }
    assert pull && rm && run, calls.join("\n")
    assert pull < rm, "the image must be pulled before the running connector is removed"
    assert rm < run

    run_line = calls[run]
    assert_match(/--network host/, run_line)
    assert_match(/--restart unless-stopped/, run_line)
    assert_match(/--label zimmer\.cloudflared\.spec=#{spec_for(TOKEN)}/, run_line)
    assert_match(%r{#{Regexp.escape(IMAGE)} tunnel run --token-file #{Regexp.escape(@token_dir)}/token}, run_line)

    assert_equal TOKEN, File.read(File.join(@token_dir, "token"))
    assert_match(/is connected/, out)
  end

  test "the token never appears on a command line" do
    registered!
    converge("CLOUDFLARE_TUNNEL_TOKEN" => TOKEN)

    refute_includes ssh_argv, TOKEN, "the token was passed as an ssh argument"
    refute(docker_calls.any? { _1.include?(TOKEN) }, "the token was passed as a docker argument")
  end

  test "a converged host is left running untouched" do
    running!(spec_for(TOKEN))
    registered!
    out, status = converge("CLOUDFLARE_TUNNEL_TOKEN" => TOKEN)

    assert status.success?, out
    assert_match(/leaving it alone/, out)
    assert_empty docker_calls.grep(/docker (pull|rm|run)/)
  end

  test "a rotated token recreates the connector" do
    running!(spec_for("b2xkLXRva2Vu"))
    registered!
    out, status = converge("CLOUDFLARE_TUNNEL_TOKEN" => TOKEN)

    assert status.success?, out
    assert docker_calls.any? { _1.start_with?("docker run") }, "a new token must recreate the connector"
  end

  test "a connector that never registers fails the deploy" do
    out, status = converge("CLOUDFLARE_TUNNEL_TOKEN" => TOKEN)

    refute status.success?, out
    assert_match(/registered no tunnel connection/, out)
  end

  test "something that is not a token is refused before anything reaches the host" do
    out, status = converge("CLOUDFLARE_TUNNEL_TOKEN" => "abc; rm -rf /")

    assert_equal 2, status.exitstatus, out
    refute File.exist?(File.join(@dir, "argv.log")), "the script reached the host with an invalid token"
  end
end
