# frozen_string_literal: true

require "test_helper"
require "open3"
require "shellwords"

# The uid boundary itself, for real: a process started through SessionUid.wrap must not
# be able to read the worker's /proc/<pid>/environ, the app's credentials file, or another
# session's files — and must still be able to use its own.
#
# Switching uid needs root, which a test process does not have. So this runs the scenario
# in a throwaway container where it IS root, using exactly what production uses:
#
#   * the capability set bin/docker-entrypoint grants the app (read from the file),
#   * the handover argv SessionUid::Sandbox runs (Sandbox.chown_command),
#   * the spawn argv SessionUid.wrap builds, and the out-of-scope one strip_capabilities builds.
#
# It needs Docker. On a developer machine without it the test skips; under CI (the
# GitHub-hosted runner has Docker) a missing daemon FAILS, so the boundary is never
# silently untested where it matters.
class SessionUidBoundaryTest < ActiveSupport::TestCase
  IMAGE = "debian:bookworm-slim"
  AGENT_UID = 20_001
  OTHER_UID = 20_002

  setup do
    unless docker_available?
      flunk "Docker is required for the uid boundary test under CI" if ENV["CI"].present?
      skip "Docker is not available; the uid boundary test runs under CI"
    end
  end

  test "an isolated session cannot read the worker's environment, the app's credentials or another session" do
    output = run_scenario

    # Who the agent is, and what it holds.
    assert_includes output, "AGENT_ID=#{AGENT_UID}"
    assert_match(/^AGENT CapEff:\s+0+$/, output, "the agent kept a capability")
    assert_match(/^AGENT CapAmb:\s+0+$/, output, "the agent kept an ambient capability")
    assert_match(/^AGENT NoNewPrivs:\s+1$/, output, "the agent could regain privileges through a setuid binary")
    assert_includes output, "AGENT_GROUPS=#{AGENT_UID}", "the agent kept a supplementary group (the Docker socket's)"

    # What it must not reach. Each LEAK_ line is the failure this test exists for.
    refute_includes output, "LEAK_ENVIRON", "the agent read the worker's /proc/<pid>/environ"
    assert_includes output, "ok-environ"
    refute_includes output, "LEAK_SECRET_VALUE", "the worker's secret value reached the agent"
    refute_includes output, "LEAK_CREDENTIALS", "the agent read the app's credentials file"
    assert_includes output, "ok-credentials"
    refute_includes output, "LEAK_HOME_LIST", "the agent listed the app's HOME"
    refute_includes output, "LEAK_OTHER_SESSION", "the agent read another session's files"
    refute_includes output, "LEAK_SIGNAL", "the agent could signal the worker"

    # What it must still be able to do.
    assert_includes output, "ok-own-file", "the agent could not read a file the app handed it"
    assert_includes output, "ok-own-write", "the agent could not write into its own directory"
    assert_includes output, "OWN_MODE=600", "the agent's umask is not 077"

    # The app, holding its ambient set, can still read what the agent wrote 0600.
    assert_includes output, "ok-app-reads-agent-file"

    # An out-of-scope session runs as the app's uid but without the app's capabilities.
    assert_includes output, "STRIPPED_ID=1000"
    assert_match(/^STRIPPED CapEff:\s+0+$/, output, "an out-of-scope session inherited the app's capabilities")
    assert_match(/^STRIPPED CapAmb:\s+0+$/, output)
  end

  private

  def docker_available?
    _out, _err, status = Open3.capture3("docker", "info")
    status.success?
  rescue SystemCallError
    false
  end

  def app_capabilities
    Rails.root.join("bin/docker-entrypoint").read[/zimmer_caps="([^"]+)"/, 1] ||
      flunk("bin/docker-entrypoint no longer names the app's capability set")
  end

  def shell(argv)
    argv.map { |arg| Shellwords.escape(arg) }.join(" ")
  end

  def run_scenario
    agent = SessionUid.wrap([ "/bin/bash", "/probe.sh" ], uid: AGENT_UID, env: {})
    stripped = SessionUid.stub(:enabled?, true) do
      SessionUid.stub(:ambient_capabilities?, true) do
        SessionUid.strip_capabilities([ "/bin/bash", "/stripped.sh" ])
      end
    end

    probe = <<~SH
      echo "AGENT_ID=$(id -u)"
      echo "AGENT_GROUPS=$(id -G)"
      grep -E '^(CapEff|CapAmb|NoNewPrivs):' /proc/self/status | sed 's/^/AGENT /'
      if cat "/proc/$WPID/environ" >/tmp/agent-environ 2>/dev/null; then echo LEAK_ENVIRON; else echo ok-environ; fi
      if grep -q worker-secret-value /tmp/agent-environ 2>/dev/null; then echo LEAK_SECRET_VALUE; fi
      if cat /home/rails/.claude/.credentials.json >/dev/null 2>&1; then echo LEAK_CREDENTIALS; else echo ok-credentials; fi
      if ls /home/rails >/dev/null 2>&1; then echo LEAK_HOME_LIST; fi
      if cat /srv/sessions/s2/notes >/dev/null 2>&1; then echo LEAK_OTHER_SESSION; fi
      if kill -0 "$WPID" 2>/dev/null; then echo LEAK_SIGNAL; fi
      if grep -q app-wrote /srv/sessions/s1/mcp.json; then echo ok-own-file; fi
      if echo agent-wrote > /srv/sessions/s1/agent-file; then echo ok-own-write; fi
      echo "OWN_MODE=$(stat -c %a /srv/sessions/s1/agent-file)"
    SH

    stripped_probe = <<~SH
      echo "STRIPPED_ID=$(id -u)"
      grep -E '^(CapEff|CapAmb):' /proc/self/status | sed 's/^/STRIPPED /'
    SH

    # Runs as uid 1000 holding the entrypoint's ambient set, under the app's umask.
    app = <<~SH
      set -e
      umask 077
      mkdir -p /home/rails/.claude
      echo '{"claudeAiOauth":"SECRET"}' > /home/rails/.claude/.credentials.json
      chmod 0711 /home/rails
      WORKER_SECRET=worker-secret-value sleep 300 &
      export WPID=$!
      mkdir -p /srv/sessions/s1 /srv/sessions/s2
      echo app-wrote > /srv/sessions/s1/mcp.json
      echo other-session > /srv/sessions/s2/notes
      #{shell(SessionUid::Sandbox.chown_command(AGENT_UID, "/srv/sessions/s1"))}
      #{shell(SessionUid::Sandbox.chown_command(OTHER_UID, "/srv/sessions/s2"))}
      chmod 0700 /srv/sessions/s1 /srv/sessions/s2
      #{shell(agent)} || true
      if grep -q agent-wrote /srv/sessions/s1/agent-file; then echo ok-app-reads-agent-file; fi
      #{shell(stripped)} || true
      kill "$WPID"
    SH

    root = <<~SH
      set -e
      groupadd -g 1000 rails
      useradd -u 1000 -g 1000 -m -d /home/rails rails
      chmod 0700 /home/rails
      mkdir -p /srv/sessions && chown 1000:1000 /srv/sessions && chmod 0711 /srv/sessions
      caps=#{Shellwords.escape(app_capabilities)}
      exec setpriv --reuid=1000 --regid=1000 --init-groups --inh-caps="$caps" --ambient-caps="$caps" /bin/bash /app.sh
    SH

    Dir.mktmpdir do |dir|
      { "root.sh" => root, "app.sh" => app, "probe.sh" => probe, "stripped.sh" => stripped_probe }.each do |name, body|
        File.write(File.join(dir, name), body)
        File.chmod(0o644, File.join(dir, name))
      end
      File.chmod(0o755, dir)

      mounts = %w[root.sh app.sh probe.sh stripped.sh].flat_map { |name| [ "-v", "#{dir}/#{name}:/#{name}:ro" ] }
      out, err, status = Open3.capture3("docker", "run", "--rm", *mounts, IMAGE, "/bin/bash", "/root.sh")
      assert status.success?, "the scenario container failed:\n#{out}\n#{err}"
      out
    end
  end
end
