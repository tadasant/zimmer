# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# Drives the watchdog installer against a fake host: `ssh` is stubbed on PATH and
# *evaluates* the remote command locally, with the absolute paths rewritten into a
# throwaway root. So these tests assert what actually lands on a box -- the script body,
# the unit, the timer, the settings file -- rather than the strings the installer meant
# to send.
#
# Two properties are load-bearing enough to be pinned here, because both are about a
# caller other than staging's deploy being able to use this script at all:
#
#   1. With ZIMMER_WATCHDOG_SSH_EXTRA unset, the ssh argument list is EXACTLY what it was
#      before the hook existed. Staging's `bash scripts/install-worker-watchdog.sh $HOST`
#      is the one call site that must not move.
#   2. A settings file placed by a deploy survives every subsequent converge. Production
#      runs with recovery off (restarting the worker there kills live agent sessions), so
#      a value that quietly reverted to the default on the next deploy would be worse
#      than no setting at all.
class InstallWorkerWatchdogTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("scripts", "install-worker-watchdog.sh")
  WATCHDOG_SRC = Rails.root.join("scripts", "worker-watchdog.sh")

  DEFAULTS_PATH = "/etc/default/zimmer-worker-watchdog"
  INSTALLED_PATH = "/usr/local/sbin/zimmer-worker-watchdog"
  TIMER_PATH = "/etc/systemd/system/zimmer-worker-watchdog.timer"
  SERVICE_PATH = "/etc/systemd/system/zimmer-worker-watchdog.service"

  # The ssh options the installer has always passed. Pinned so that a change to them is
  # a deliberate edit to this list and not a side effect of the hook.
  BASE_SSH_OPTS = [
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=15",
    "-o", "ServerAliveInterval=10",
    "-o", "ServerAliveCountMax=3"
  ].freeze

  # Records argv tab-separated, then runs the remote command against $FAKEROOT. The
  # remote commands are single-line, so one invocation is one line of the log.
  SSH_STUB = <<~SH
    printf '%s\\t' "$@" >> "$ARGV_LOG"
    printf '\\n' >> "$ARGV_LOG"
    cmd="${!#}"
    cmd=${cmd//\\/usr\\/local\\/sbin/${FAKEROOT}/usr/local/sbin}
    cmd=${cmd//\\/etc\\//${FAKEROOT}/etc/}
    eval "$cmd"
  SH

  # A host that answers everything. `is-active --quiet` returning 0 is what keeps the
  # installer on its success path.
  SYSTEMCTL_STUB = "exit 0"
  JOURNALCTL_STUB = "echo 'exec probe OK'"

  class Host
    attr_reader :root, :argv_log

    def initialize(dir)
      @dir = dir
      @root = File.join(dir, "fakeroot")
      @argv_log = File.join(dir, "argv.log")
      %w[usr/local/sbin etc/default etc/systemd/system].each do |sub|
        FileUtils.mkdir_p(File.join(@root, sub))
      end
      stub("ssh", SSH_STUB)
      stub("systemctl", SYSTEMCTL_STUB)
      stub("journalctl", JOURNALCTL_STUB)
    end

    def stub(name, body)
      path = File.join(bin, name)
      FileUtils.mkdir_p(bin)
      File.write(path, "#!/usr/bin/env bash\n#{body}\n")
      File.chmod(0o755, path)
    end

    def bin = File.join(@dir, "bin")

    def read(remote_path) = File.read(File.join(@root, remote_path.delete_prefix("/")))
    def exist?(remote_path) = File.exist?(File.join(@root, remote_path.delete_prefix("/")))

    def write(remote_path, content)
      File.write(File.join(@root, remote_path.delete_prefix("/")), content)
    end

    # One entry per ssh invocation: the argv up to (and excluding) the destination.
    def ssh_option_lists
      return [] unless File.exist?(@argv_log)

      File.readlines(@argv_log, chomp: true).map do |line|
        line.split("\t").take_while { |arg| !arg.start_with?("root@") }
      end
    end

    def converge(host: "testhost", env: {})
      full_env = {
        "PATH" => "#{bin}:#{ENV['PATH']}",
        "FAKEROOT" => @root,
        "ARGV_LOG" => @argv_log
      }.merge(env.transform_values(&:to_s))
      stdout, stderr, status = Open3.capture3(full_env, "bash", SCRIPT.to_s, *Array(host))
      [ status.exitstatus, stdout + stderr ]
    end
  end

  def with_host
    Dir.mktmpdir { |dir| yield Host.new(dir) }
  end

  # --- the call site that must not move -------------------------------------

  test "converges a host and leaves the ssh arguments exactly as they were" do
    with_host do |host|
      code, out = host.converge

      assert_equal 0, code, out
      assert_match(/Watchdog armed on testhost/, out)

      option_lists = host.ssh_option_lists
      assert_operator option_lists.length, :>=, 5, "expected the installer to talk to the host"
      option_lists.each do |opts|
        # `run_q` closes stdin with -n; everything else is the pinned list, unchanged.
        assert_equal BASE_SSH_OPTS, opts.reject { |arg| arg == "-n" }
      end
    end
  end

  test "installs the watchdog byte-for-byte, with a unit and a 60s timer" do
    with_host do |host|
      code, out = host.converge
      assert_equal 0, code, out

      assert_equal File.read(WATCHDOG_SRC), host.read(INSTALLED_PATH)
      assert_match(%r{ExecStart=/usr/local/sbin/zimmer-worker-watchdog}, host.read(SERVICE_PATH))
      assert_match(/EnvironmentFile=-#{Regexp.escape(DEFAULTS_PATH)}/, host.read(SERVICE_PATH))
      assert_match(/OnUnitActiveSec=60s/, host.read(TIMER_PATH))
    end
  end

  test "honours ZIMMER_WATCHDOG_INTERVAL" do
    with_host do |host|
      code, out = host.converge(env: { "ZIMMER_WATCHDOG_INTERVAL" => "30s" })

      assert_equal 0, code, out
      assert_match(/OnUnitActiveSec=30s/, host.read(TIMER_PATH))
    end
  end

  test "re-running changes nothing" do
    with_host do |host|
      assert_equal 0, host.converge.first
      first = %w[/usr/local/sbin/zimmer-worker-watchdog /etc/default/zimmer-worker-watchdog
                 /etc/systemd/system/zimmer-worker-watchdog.service
                 /etc/systemd/system/zimmer-worker-watchdog.timer].to_h { |p| [ p, host.read(p) ] }

      assert_equal 0, host.converge.first
      first.each { |path, content| assert_equal content, host.read(path), "#{path} drifted on the second run" }
    end
  end

  # --- the hook -------------------------------------------------------------

  test "ZIMMER_WATCHDOG_SSH_EXTRA is threaded into every ssh invocation, ahead of the defaults" do
    with_host do |host|
      config = File.join(host.root, "ssh_config")
      File.write(config, "Host testhost\n  HostName 127.0.0.1\n")

      code, out = host.converge(env: { "ZIMMER_WATCHDOG_SSH_EXTRA" => "-F #{config} -o ConnectTimeout=45" })

      assert_equal 0, code, out
      host.ssh_option_lists.each do |opts|
        opts = opts.reject { |arg| arg == "-n" }
        # Ahead of the defaults, because ssh takes the FIRST value it obtains for an
        # option: appending would leave the caller unable to override ConnectTimeout.
        assert_equal [ "-F", config, "-o", "ConnectTimeout=45" ] + BASE_SSH_OPTS, opts
      end
    end
  end

  test "an empty ZIMMER_WATCHDOG_SSH_EXTRA is inert" do
    with_host do |host|
      code, out = host.converge(env: { "ZIMMER_WATCHDOG_SSH_EXTRA" => "" })

      assert_equal 0, code, out
      host.ssh_option_lists.each { |opts| assert_equal BASE_SSH_OPTS, opts.reject { |a| a == "-n" } }
    end
  end

  test "a failing ssh fails the converge instead of reporting an armed watchdog" do
    with_host do |host|
      host.stub("ssh", "exit 255")

      code, out = host.converge

      refute_equal 0, code
      refute_match(/Watchdog armed/, out)
    end
  end

  # --- the settings file ----------------------------------------------------

  test "seeds the commented template when the host has no settings file" do
    with_host do |host|
      assert_equal 0, host.converge.first

      defaults = host.read(DEFAULTS_PATH)
      assert_match(/^#ZIMMER_WATCHDOG_RECOVER=1$/, defaults)
      refute_match(/^ZIMMER_WATCHDOG_RECOVER=/, defaults, "the seeded template must not set anything")
    end
  end

  test "a settings file already on the host survives every converge" do
    with_host do |host|
      placed = "# placed by the deploy\nZIMMER_WATCHDOG_RECOVER=0\n"
      host.write(DEFAULTS_PATH, placed)

      2.times { assert_equal 0, host.converge.first }

      assert_equal placed, host.read(DEFAULTS_PATH)
    end
  end

  test "ZIMMER_WATCHDOG_RECOVER=0 is asserted declaratively, on every run" do
    with_host do |host|
      code, out = host.converge(env: { "ZIMMER_WATCHDOG_RECOVER" => "0" })

      assert_equal 0, code, out
      assert_match(/Asserting ZIMMER_WATCHDOG_RECOVER=0/, out)
      assert_match(/^ZIMMER_WATCHDOG_RECOVER=0$/, host.read(DEFAULTS_PATH))
      assert_match(/MANAGED BY THE DEPLOY/, host.read(DEFAULTS_PATH))

      # The point of declaring it: a hand edit on the box does not outlive the next
      # deploy. Recovery on production is a safety setting, not a preference.
      host.write(DEFAULTS_PATH, "ZIMMER_WATCHDOG_RECOVER=1\n")
      assert_equal 0, host.converge(env: { "ZIMMER_WATCHDOG_RECOVER" => "0" }).first
      assert_match(/^ZIMMER_WATCHDOG_RECOVER=0$/, host.read(DEFAULTS_PATH))
    end
  end

  test "ZIMMER_WATCHDOG_RECOVER=1 is asserted the same way" do
    with_host do |host|
      host.write(DEFAULTS_PATH, "ZIMMER_WATCHDOG_RECOVER=0\n")

      assert_equal 0, host.converge(env: { "ZIMMER_WATCHDOG_RECOVER" => "1" }).first
      assert_match(/^ZIMMER_WATCHDOG_RECOVER=1$/, host.read(DEFAULTS_PATH))
    end
  end

  test "the managed settings file is sourceable and leaves no temp file behind" do
    with_host do |host|
      assert_equal 0, host.converge(env: { "ZIMMER_WATCHDOG_RECOVER" => "0" }).first

      path = File.join(host.root, DEFAULTS_PATH.delete_prefix("/"))
      out, status = Open3.capture2e("bash", "-c", ". '#{path}' && echo \"recover=$ZIMMER_WATCHDOG_RECOVER\"")
      assert status.success?, out
      assert_match(/recover=0/, out)
      refute host.exist?("/etc/default/.zimmer-worker-watchdog.new")
    end
  end

  test "a nonsense ZIMMER_WATCHDOG_RECOVER is rejected before anything is touched" do
    with_host do |host|
      code, out = host.converge(env: { "ZIMMER_WATCHDOG_RECOVER" => "yes" })

      assert_equal 2, code
      assert_match(/must be 0, 1, or unset/, out)
      assert_empty host.ssh_option_lists, "the host must not be touched after a bad declaration"
      refute host.exist?(INSTALLED_PATH)
    end
  end

  test "requires a host argument" do
    with_host do |host|
      code, out = host.converge(host: [])

      refute_equal 0, code
      assert_match(/usage/, out)
    end
  end
end
