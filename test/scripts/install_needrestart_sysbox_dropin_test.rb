# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# Drives the needrestart drop-in installer against a fake host, the same way
# InstallWorkerWatchdogTest does: `ssh` is stubbed on PATH and *runs* the remote script
# locally, with /etc/needrestart rewritten into a throwaway root. So these tests assert
# what lands on a box and what the assertions do about it, rather than the strings the
# installer meant to send.
#
# The remote half is where all the behaviour lives, and none of it is reachable by any
# other check in this repo: `shellcheck` and `bash -n` do not descend into a heredoc body,
# so the embedded Perl, the created/updated/unchanged reporting, the box-without-needrestart
# branch and the conf.d-loop-is-gone branch are covered here or nowhere.
#
# Two properties are load-bearing enough to pin:
#
#   1. A snippet that does not compile, or that reassigns `override_rc` instead of merging
#      into it, must never reach `/etc/needrestart/conf.d/*.conf`. needrestart `die`s on a
#      file it cannot parse and it is unattended-upgrades that carries the error, so a bad
#      file aborts every upgrade run on the box -- worse than the exposure it was meant to
#      close. The installer therefore validates the STAGED file and only then moves it.
#   2. Re-running changes nothing. This runs on every deploy.
#
# The stub runs the remote script under `sh`, not bash, because the real one runs under
# dash on the droplet.
class InstallNeedrestartSysboxDropinTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("scripts", "install-needrestart-sysbox-dropin.sh")

  CONF_D = "/etc/needrestart/conf.d"
  DROPIN = "#{CONF_D}/99-sysbox.conf"
  STAGED = "#{CONF_D}/.99-sysbox.conf.new"
  NEEDRESTART_CONF = "/etc/needrestart/needrestart.conf"

  # The ssh options the installer passes. Pinned so a change to them is a deliberate edit
  # to this list -- the other two converge scripts here carry the identical set, and they
  # are what bound a silent session against a thrashing box.
  BASE_SSH_OPTS = [
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=15",
    "-o", "ServerAliveInterval=10",
    "-o", "ServerAliveCountMax=3"
  ].freeze

  # Records argv, then runs the remote script -- which arrives on stdin, since the
  # installer calls `ssh host 'sh -s'` -- against $FAKEROOT under a real `sh`.
  SSH_STUB = <<~SH
    printf '%s\\t' "$@" >> "$ARGV_LOG"
    printf '\\n' >> "$ARGV_LOG"
    remote="$(mktemp)"
    sed "s#/etc/needrestart#${FAKEROOT}/etc/needrestart#g" > "$remote"
    sh "$remote"
    rc=$?
    rm -f "$remote"
    exit $rc
  SH

  # The stock config's shape: `override_rc` assigned near the top, the conf.d eval loop
  # near the bottom. Both halves matter -- the assignment is what the drop-in merges into,
  # and the loop is what the installer's third assertion greps for.
  STOCK_NEEDRESTART_CONF = <<~PERL
    $nrconf{override_rc} = {
        qr(^dbus) => 0,
        qr(^docker) => 0,
        qr(^lightdm) => 0,
    };

    if(-d q(/etc/needrestart/conf.d)) {
          foreach my $fn (sort </etc/needrestart/conf.d/*.conf>) {
                  eval do { local(@ARGV, $/) = $fn; <>};
                  die "Error parsing $fn: $@" if($@);
          }
    }
  PERL

  class Host
    attr_reader :root, :argv_log

    def initialize(dir)
      @dir = dir
      @root = File.join(dir, "fakeroot")
      @argv_log = File.join(dir, "argv.log")
      FileUtils.mkdir_p(File.join(@root, CONF_D.delete_prefix("/")))
      # The stub rewrites /etc/needrestart into $FAKEROOT throughout the remote script, so
      # the fixture has to carry the same rewrite: on a real host the path the installer
      # greps for and the path inside needrestart.conf are the same string, and the test is
      # only faithful if they stay the same string here too.
      write(NEEDRESTART_CONF, rerooted(STOCK_NEEDRESTART_CONF))
      stub("ssh", SSH_STUB)
      install_needrestart
    end

    def bin = File.join(@dir, "bin")

    def stub(name, body)
      FileUtils.mkdir_p(bin)
      path = File.join(bin, name)
      File.write(path, "#!/usr/bin/env bash\n#{body}\n")
      File.chmod(0o755, path)
    end

    # `needrestart --version` is the only invocation the installer makes of the real binary,
    # and it is the presence of the command on PATH that selects the branch.
    def install_needrestart = stub("needrestart", "echo 'needrestart 3.6 - Restart daemons after library updates.'")

    # Dropping the stub is not enough to make the command absent: needrestart is
    # preinstalled on Ubuntu, so a CI image built from one has a real /usr/sbin/needrestart
    # that `command -v` finds the moment the stub goes. (It is absent from the dev
    # container, which is why this passed locally and failed on the runner.) So take out
    # every directory on PATH that carries one, and let the test say what it means: this
    # box does not have needrestart.
    def uninstall_needrestart
      FileUtils.rm_f(File.join(bin, "needrestart"))
      @hidden_dirs = ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
                                .select { |d| File.executable?(File.join(d, "needrestart")) }
    end

    def abs(remote_path) = File.join(@root, remote_path.delete_prefix("/"))
    def read(remote_path) = File.read(abs(remote_path))
    def exist?(remote_path) = File.exist?(abs(remote_path))
    def write(remote_path, content) = File.write(abs(remote_path), content)
    def rm_rf(remote_path) = FileUtils.rm_rf(abs(remote_path))
    def rerooted(text) = text.gsub("/etc/needrestart", File.join(@root, "etc/needrestart"))

    def ssh_option_lists
      return [] unless File.exist?(@argv_log)

      File.readlines(@argv_log, chomp: true).map do |line|
        line.split("\t").take_while { |arg| !arg.start_with?("root@") }
      end
    end

    def converge(host: "testhost", script: SCRIPT.to_s)
      path = ([ bin ] + ENV["PATH"].to_s.split(File::PATH_SEPARATOR) - Array(@hidden_dirs))
             .join(File::PATH_SEPARATOR)
      env = { "PATH" => path, "FAKEROOT" => @root, "ARGV_LOG" => @argv_log }
      stdout, stderr, status = Open3.capture3(env, "bash", script, host)
      [ status.exitstatus, stdout + stderr ]
    end

    # Rewrites the snippet body inside the installer's own heredoc and returns the path to
    # the result, so a failure test drives the REAL script with a bad payload rather than
    # asserting against a hand-built copy of it.
    def sabotaged(original, replacement)
      body = File.read(SCRIPT)
      raise "the snippet moved; update this test's anchor" unless body.include?(original)

      path = File.join(@dir, "sabotaged.sh")
      File.write(path, body.sub(original, replacement))
      path
    end
  end

  def with_host
    Dir.mktmpdir { |dir| yield Host.new(dir) }
  end

  # Evaluates a drop-in the way needrestart does -- stock hash first, then the snippet --
  # and reports which unit names come back deselected. This is the question the whole
  # change exists to answer, asked independently of the installer's own assertion.
  def deselected_units(dropin_path, units)
    program = <<~PERL
      our %nrconf;
      $nrconf{override_rc} = { qr(^dbus) => 0, qr(^docker) => 0, qr(^lightdm) => 0 };
      eval do { local(@ARGV, $/) = $ARGV[0]; <> };
      die $@ if $@;
      for my $unit (@ARGV[1..$#ARGV]) {
        print "$unit\\n" if grep { $unit =~ /$_/ && $nrconf{override_rc}{$_} eq "0" } keys %{$nrconf{override_rc}};
      }
    PERL
    out, _err, _status = Open3.capture3("perl", "-e", program, dropin_path, *units)
    out.split("\n")
  end

  # --- the happy path -------------------------------------------------------

  test "converges a host and leaves the ssh arguments as the other converge scripts pass them" do
    with_host do |host|
      code, out = host.converge

      assert_equal 0, code, out
      assert_match(/drop-in created at/, out)
      assert_match(/will not auto-restart sysbox/, out)

      # One conversation, not one per operation: the write and the assertions have to see
      # the same box, so splitting them across invocations would be a regression.
      assert_equal 1, host.ssh_option_lists.length, "the installer's conversation with the host changed"
      assert_equal BASE_SSH_OPTS, host.ssh_option_lists.first
    end
  end

  test "the drop-in it writes deselects the sysbox units and nothing else" do
    with_host do |host|
      assert_equal 0, host.converge.first

      dropin = host.abs(DROPIN)
      assert_equal %w[sysbox.service sysbox-mgr.service sysbox-fs.service],
                   deselected_units(dropin, %w[sysbox.service sysbox-mgr.service sysbox-fs.service kamal-proxy.service])

      # The stock entries survive the merge. A bare assignment would take out `^docker`
      # along with them, which on this host means handing unattended-upgrades permission
      # to restart Docker out from under every container.
      assert_equal %w[dbus.service docker.service],
                   deselected_units(dropin, %w[dbus.service docker.service])

      assert_equal 0o644, File.stat(dropin).mode & 0o7777
      assert_match(%r{scripts/install-needrestart-sysbox-dropin\.sh}, host.read(DROPIN),
                   "the file must name the thing that manages it")
    end
  end

  test "re-running changes nothing" do
    with_host do |host|
      assert_equal 0, host.converge.first
      first = host.read(DROPIN)

      code, out = host.converge
      assert_equal 0, code, out
      assert_match(/already current/, out)
      assert_equal first, host.read(DROPIN)
    end
  end

  test "a hand-written pet file at the same path is replaced, and the replacement is reported" do
    with_host do |host|
      host.write(DROPIN, "# written by hand while triaging\n$nrconf{override_rc} = { qr(^sysbox) => 0 };\n")

      code, out = host.converge

      assert_equal 0, code, out
      assert_match(/drop-in updated at .* \(\h{32} -> \h{32}\)/, out)
      refute_match(/written by hand/, host.read(DROPIN))
    end
  end

  test "a host with no conf.d at all gets one" do
    with_host do |host|
      host.rm_rf(CONF_D)

      code, out = host.converge

      assert_equal 0, code, out
      assert_match(/drop-in created at/, out)
      assert host.exist?(DROPIN)
    end
  end

  # --- the box that is not exposed yet --------------------------------------

  test "a host without needrestart still gets the file, and is not told it is protected" do
    with_host do |host|
      host.uninstall_needrestart

      code, out = host.converge

      assert_equal 0, code, out
      assert host.exist?(DROPIN)
      assert_match(/needrestart is not installed/, out)
      refute_match(/needrestart evaluates/, out, "the installed branch ran; needrestart was still on PATH")
      assert_match(/takes effect if needrestart is ever installed/, out)
      refute_match(/will not auto-restart sysbox/, out,
                   "claiming the host is protected by a package it does not have")
    end
  end

  # --- the failures that must not publish a file ----------------------------

  test "a snippet that would break every upgrade run on the box is never published" do
    with_host do |host|
      # A file needrestart cannot parse aborts the dpkg run that invoked it, so this is
      # the one outcome strictly worse than leaving sysbox exposed.
      code, out = host.converge(script: host.sabotaged(SNIPPET, "$nrconf{override_rc} = { qr(^sysbox) => 0 ;"))

      assert_equal 1, code, out
      refute host.exist?(DROPIN), "a snippet that does not compile reached /etc/needrestart/conf.d"
      refute host.exist?(STAGED), "the staged file was left behind in a directory needrestart reads"

      # perl exits 255 on a compile error, which is also ssh's "never got a session". The
      # remote script remaps its own failures off 255 so the deploy log points at the
      # snippet rather than sending someone to check the tailnet.
      assert_match(/Reached testhost/, out)
      assert_match(/exited 4/, out)
      refute_match(/reachability problem/, out)
    end
  end

  test "a snippet that reassigns override_rc instead of merging is never published" do
    with_host do |host|
      # Parses, deselects sysbox, and silently drops the 43 stock entries with it.
      code, out = host.converge(script: host.sabotaged(SNIPPET, "$nrconf{override_rc} = { qr(^sysbox) => 0 };"))

      assert_equal 1, code, out
      assert_match(/REPLACED override_rc instead of merging/, out)
      refute host.exist?(DROPIN)
      refute host.exist?(STAGED)
    end
  end

  test "a snippet whose regex no longer matches a sysbox unit is never published" do
    with_host do |host|
      code, out = host.converge(script: host.sabotaged(SNIPPET, SNIPPET.sub("^sysbox", "^syzbox")))

      assert_equal 1, code, out
      assert_match(/not deselected by any override_rc key/, out)
      refute host.exist?(DROPIN)
    end
  end

  test "a needrestart that no longer reads conf.d fails loudly instead of leaving an inert file" do
    with_host do |host|
      # The drop-in only works because needrestart.conf evals conf.d. That file is
      # rewritten by package upgrades; if the loop goes away the override is inert, and
      # nothing else on the box would ever say so.
      host.write(NEEDRESTART_CONF, "$nrconf{override_rc} = { qr(^dbus) => 0 };\n")

      code, out = host.converge

      assert_equal 1, code, out
      assert_match(/no longer evaluates/, out)
      assert_match(/is inert/, out)
    end
  end

  test "an unreachable host is reported as a reachability problem, not a needrestart one" do
    with_host do |host|
      host.stub("ssh", "cat > /dev/null; exit 255")

      code, out = host.converge

      assert_equal 1, code, out
      assert_match(/reachability problem, not a needrestart one/, out)
      refute_match(/Reached testhost/, out)
    end
  end

  # The snippet as the installer writes it. Anchored here so a sabotage test fails loudly
  # if it is ever reworded, instead of silently testing an unmodified script.
  SNIPPET = "$nrconf{override_rc} = { %{$nrconf{override_rc} // {}}, qr(^sysbox) => 0 };"
end
