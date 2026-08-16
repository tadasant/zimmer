# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The privilege drop `bin/docker-entrypoint` performs when the container starts as root.
#
# This exists because of the 2026-08-13 production freeze. Nested Docker runs the worker
# with `user: "0:0"`, and Docker derives HOME from `--user`, so HOME was `/root`. `setpriv`
# changes credentials and NOT the environment, so the app then ran as uid 1000 with
# HOME=/root -- a directory that is mode 0700 and owned by root.
#
# libpq probes `$HOME/.postgresql/postgresql.crt` on every TLS connection and tolerates
# only ENOENT/ENOTDIR; EACCES is fatal. So the worker opened no database connection at all
# for ten hours: it booted, it logged, it claimed nothing, and every container-shaped check
# stayed green because the container really was up.
#
# The old test suite could not have caught that: it read the entrypoint as text. These
# tests RUN it, with `id`, `getent` and `setpriv` stubbed on PATH, and assert the
# environment it actually hands to the app. Nothing here needs root.
#
# What these tests deliberately do not cover is the real thing -- a worker under
# `sysbox-runc` draining a real job -- because CI has no sysbox runtime and no user
# namespace. That is verified on staging; see docs/operate/nested-docker.md.
class DockerEntrypointPrivilegeDropTest < ActiveSupport::TestCase
  ENTRYPOINT = Rails.root.join("bin/docker-entrypoint").to_s

  # Stubs the three commands the root branch shells out to, so it can run unprivileged:
  #
  #   id       -- claim to be uid 0, which is what puts us on the branch at all
  #   getent   -- answer the passwd lookup with a home we control, so the assertion does
  #               not depend on whether /home/rails exists on the CI runner
  #   setpriv  -- stand in for both calls the entrypoint makes: the probe, whose `test`
  #               it runs (as this process's own uid, via bash's builtin -- so these
  #               tests cover the entrypoint's logic, NOT setpriv's ability to assume
  #               uid 1000), and the final re-exec, which reports the environment
  #               instead of running the app. It echoes its own argv first, because
  #               WHICH credentials it is asked for is half of what this file guards:
  #               a handover that re-exec'd as `--reuid=0` would leave the app running
  #               as root, which is the thing the whole block exists to prevent, and
  #               a stub that swallowed its flags could not tell the difference.
  #   chown    -- the reclaim sweep's only side effect, recorded rather than performed
  #               (these tests are not root, and `find`/`chown` are the sweep's whole
  #               implementation, so its argv IS its behaviour)
  #   find     -- records argv and then hands off to the real binary, so the sweep's
  #               scope is assertable without faking what it actually finds
  #
  # Those last two record to a file rather than to stdout, and the file is the third
  # element `run_entrypoint` returns. They have no usable stream: the sweep redirects
  # find's stdout into the list it is building, and both its stderr and xargs' into
  # /dev/null, so anything either stub printed would land in the data or be discarded.
  #
  #   sleep    -- fails, which ends the `while sleep` repeat loop after zero
  #               iterations. The loop is forked and inherits stdout, so a real sleep
  #               would hold the pipe `IO.popen` reads until the interval elapsed --
  #               forever, at the default 60s, since the loop never ends on its own.
  #               `sleep_succeeds_once:` lets one iteration through instead.
  #
  # Pass `passwd: nil` to make the lookup find no uid 1000 at all.
  def run_entrypoint(app_home:, env: {}, app_name: "rails", passwd: :present, sleep_succeeds_once: false)
    Dir.mktmpdir do |stubs|
      write_stub stubs, "id", <<~SH
        #!/bin/bash
        if [ "$1" = "-u" ]; then echo 0; else exit 0; fi
      SH

      write_stub stubs, "getent", passwd.nil? ? "#!/bin/bash\nexit 2\n" : <<~SH
        #!/bin/bash
        echo "#{app_name}:x:1000:1000::#{app_home}:/bin/bash"
      SH

      # The entrypoint falls back to awk over the real /etc/passwd, which on a CI
      # runner does have a uid 1000. Stub it out too, or "no app user" is untestable.
      write_stub stubs, "awk", "#!/bin/bash\nexit 0\n" if passwd.nil?

      write_stub stubs, "setpriv", <<~SH
        #!/bin/bash
        echo "SETPRIV-ARGV $*"
        while [[ "$1" == --* ]]; do shift; done
        if [ "$1" = "test" ]; then shift; test "$@"; exit $?; fi
        echo "DROPPED HOME=$HOME USER=$USER LOGNAME=$LOGNAME"
      SH

      stub_log = File.join(stubs, "stub.log")

      write_stub stubs, "chown", <<~SH
        #!/bin/bash
        echo "CHOWN-ARGV $*" >> "#{stub_log}"
      SH

      write_stub stubs, "find", <<~SH
        #!/bin/bash
        echo "FIND-ARGV $*" >> "#{stub_log}"
        exec #{real_find} "$@"
      SH

      write_stub stubs, "sleep", sleep_succeeds_once ? <<~SH : "#!/bin/bash\nexit 1\n"
        #!/bin/bash
        marker="$(dirname "$0")/.slept"
        if [ -e "$marker" ]; then exit 1; fi
        : > "$marker"
        exit 0
      SH

      # `-e` explicitly: the shebang carries it, and `bash <script>` does not honour a
      # shebang, so without it this would exercise a shell the container never runs.
      full_env = { "PATH" => "#{stubs}:#{ENV['PATH']}" }.merge(env)
      output = IO.popen(full_env, [ "bash", "-e", ENTRYPOINT, "true" ], err: %i[child out], &:read)
      [ output, $?.exitstatus, File.exist?(stub_log) ? File.read(stub_log) : "" ]
    end
  end

  # The sweep stub delegates to the real thing rather than faking results, so the
  # `! -uid 1000` predicate is exercised and not merely spelled.
  def real_find
    @real_find ||= %w[/usr/bin/find /bin/find].find { |p| File.executable?(p) } ||
      raise("no find binary to delegate to")
  end

  def write_stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  # The regression itself. Against the entrypoint as it shipped on 2026-08-13 this asserts
  # HOME=/root and fails.
  test "the privilege drop rewrites a root HOME to the app user's" do
    Dir.mktmpdir do |app_home|
      output, status = run_entrypoint(app_home: app_home, env: { "HOME" => "/root" })

      assert_equal 0, status, output
      assert_match(/DROPPED HOME=#{Regexp.escape(app_home)}\b/, output,
        "the app would run as uid 1000 with HOME=/root, which it cannot read -- libpq " \
        "fails every TLS connection with EACCES and the worker claims no jobs")
      refute_match(%r{HOME=/root}, output)
    end
  end

  # HOME is the one that broke production, but USER/LOGNAME describe the same identity and
  # a process that disagrees with itself about who it is is its own class of surprise.
  test "the privilege drop rewrites USER and LOGNAME to the app user" do
    Dir.mktmpdir do |app_home|
      output, = run_entrypoint(app_home: app_home, env: { "HOME" => "/root", "USER" => "root", "LOGNAME" => "root" })

      assert_match(/USER=rails\b/, output)
      assert_match(/LOGNAME=rails\b/, output)
    end
  end

  # A HOME the app cannot write is precisely the ten-hour outage, so the entrypoint must
  # fail loudly rather than hand over. A container that refuses to start is a failed
  # deploy; one that starts and quietly claims nothing is not.
  test "the entrypoint refuses to drop into a HOME the app user cannot write" do
    output, status = run_entrypoint(
      app_home: "/nonexistent-#{SecureRandom.hex(6)}",
      env: { "HOME" => "/root" }
    )

    assert_equal 1, status, "expected the entrypoint to refuse, got:\n#{output}"
    assert_match(/Refusing to start/, output)
    refute_match(/DROPPED/, output, "it handed over anyway")
  end

  # #496 item 2. The covered refusal above is ENOENT -- a HOME that is not there at all.
  # The route that actually froze production is EACCES: a HOME that exists, and that uid
  # 1000 cannot traverse. `/root` at mode 0700 is exactly that shape, and libpq treats the
  # two differently -- ENOENT it tolerates, EACCES is fatal -- so the tolerated one is a
  # poor stand-in for the fatal one.
  test "the entrypoint refuses a HOME that exists but the app user cannot traverse" do
    skip "running as root, which ignores the mode bits this case is made of" if Process.uid.zero?

    Dir.mktmpdir do |app_home|
      File.chmod(0o000, app_home)

      output, status = run_entrypoint(app_home: app_home, env: { "HOME" => "/root" })

      assert_equal 1, status, "expected the entrypoint to refuse, got:\n#{output}"
      assert_match(/Refusing to start/, output)
      assert_match(/cannot use HOME=#{Regexp.escape(app_home)}/, output)
      refute_match(/DROPPED/, output, "it handed over into a HOME the app cannot read")
    ensure
      # Or mktmpdir cannot remove it, and the failure surfaces as an unrelated error.
      File.chmod(0o700, app_home)
    end
  end

  # #496 item 1. Everything else here asserts the environment the app is handed; this
  # asserts the credentials, which no test did. `setpriv --reuid=0` would satisfy every
  # other assertion in this file while leaving the app running as root -- the exact
  # condition that fills the shared volumes with files uid 1000 cannot read.
  test "the handover asks setpriv for uid 1000, gid 1000 and its supplementary groups" do
    Dir.mktmpdir do |app_home|
      output, status = run_entrypoint(app_home: app_home, env: { "HOME" => "/root" })
      assert_equal 0, status, output

      calls = output.lines.grep(/^SETPRIV-ARGV /).map(&:strip)
      assert_equal 2, calls.length, "expected a probe and a handover, got:\n#{output}"

      # The probe has to ask as the uid that will have to live with the answer, or it
      # measures the wrong process's access.
      assert_equal "SETPRIV-ARGV --reuid=1000 --regid=1000 --init-groups test -x #{app_home} -a -w #{app_home}",
        calls.first

      # --init-groups and not just --regid: without it the app keeps gid 1000 alone and
      # silently loses every supplementary group the rails user belongs to.
      assert_equal "SETPRIV-ARGV --reuid=1000 --regid=1000 --init-groups #{ENTRYPOINT} true",
        calls.last
    end
  end

  # The reclaim sweep. `docker exec` inherits `user: "0:0"` and skips this script
  # entirely, so root writes into the shared volumes cannot be prevented from here --
  # only undone. What must hold is that the sweep looks in the right places.
  test "the reclaim sweeps the app's volume roots and nothing else under HOME" do
    Dir.mktmpdir do |app_home|
      FileUtils.mkdir_p([ "#{app_home}/.claude", "#{app_home}/.zimmer", "#{app_home}/.config/gh" ])
      # Not a volume, and on the container layer: sweeping it would rewrite image state.
      FileUtils.mkdir_p("#{app_home}/.cache")

      output, status, stubs = run_entrypoint(app_home: app_home, env: { "HOME" => "/root" })
      assert_equal 0, status, output

      sweep = stubs.lines.grep(/^FIND-ARGV /).first
      assert sweep, "the entrypoint never swept:\n#{output}"

      roots = sweep.split[1..].take_while { |a| a.start_with?("/") }
      assert_equal [ "#{app_home}/.claude", "#{app_home}/.config/gh", "#{app_home}/.zimmer" ], roots.sort,
        "the sweep must cover the mounted volumes, and only those"
      refute_includes roots, app_home, "sweeping all of $HOME would rewrite container-layer state"
      refute_includes roots, "#{app_home}/.cache"

      # -xdev: a dev stack's own container filesystems can appear under these paths,
      # and they are not ours to rewrite.
      assert_match(/ -xdev /, sweep)
      assert_match(/ ! -uid 1000 /, sweep)
    end
  end

  # The behaviour itself: anything in those roots not owned by uid 1000 is handed to it.
  #
  # A test cannot create a root-owned file without being root, so which half of this runs
  # depends on the uid running it -- and both halves are real. CI's runner is not uid 1000,
  # so it exercises the reclaim; a container that runs the suite AS the app user exercises
  # the no-op. Neither environment can fake its way past the other's assertion.
  test "the reclaim hands files not owned by uid 1000 back to it, and leaves the rest alone" do
    Dir.mktmpdir do |app_home|
      FileUtils.mkdir_p("#{app_home}/.claude/projects/-app")
      transcript = "#{app_home}/.claude/projects/-app/session.jsonl"
      File.write(transcript, "{}\n")
      File.chmod(0o600, transcript)

      output, status, stubs = run_entrypoint(app_home: app_home, env: { "HOME" => "/root" })
      assert_equal 0, status, output

      chowns = stubs.lines.grep(/^CHOWN-ARGV /).map(&:strip)

      if Process.uid == 1000
        assert_empty chowns, "it rewrote files that were already owned correctly"
        refute_match(/Reclaimed/, output)
      else
        assert_equal 1, chowns.length, "expected one bulk chown for the whole sweep, got:\n#{output}"
        assert_match(/\ACHOWN-ARGV -h 1000:1000 /, chowns.first,
          "-h so a symlink is retargeted rather than whatever it points at")
        assert_includes chowns.first, transcript
        assert_match(/Reclaimed \d+ root-owned path\(s\)/, output,
          "a silent repair is one nobody can confirm ran")
      end
    end
  end

  # A one-shot repair leaves the next `docker exec` free to recreate the problem, so the
  # sweep has to keep running after the handover. It is forked before the drop precisely
  # so it keeps the root credentials chown needs.
  test "the reclaim keeps sweeping after the privilege drop" do
    Dir.mktmpdir do |app_home|
      FileUtils.mkdir_p("#{app_home}/.claude")

      output, status, stubs = run_entrypoint(app_home: app_home, env: { "HOME" => "/root" }, sleep_succeeds_once: true)

      assert_equal 0, status, output
      assert_equal 2, stubs.lines.grep(/^FIND-ARGV /).length,
        "expected the boot sweep plus one repeat, got:\n#{output}"
    end
  end

  # The escape hatch, and the reason the repeat is safe to ship: a sweep that ever costs
  # more than it is worth can be turned off without redeploying a different image.
  test "ZIMMER_RECLAIM_INTERVAL=0 keeps the boot sweep and drops the repeat" do
    Dir.mktmpdir do |app_home|
      FileUtils.mkdir_p("#{app_home}/.claude")

      output, status, stubs = run_entrypoint(
        app_home: app_home,
        env: { "HOME" => "/root", "ZIMMER_RECLAIM_INTERVAL" => "0" },
        sleep_succeeds_once: true
      )

      assert_equal 0, status, output
      assert_equal 1, stubs.lines.grep(/^FIND-ARGV /).length,
        "expected the boot sweep only, got:\n#{output}"
    end
  end

  # Still the root branch -- `run_entrypoint` always stubs `id -u` to 0 -- but with an
  # environment that is already right. Normalizing must be a no-op, not a disturbance.
  test "a root container whose HOME is already the app user's is left alone" do
    Dir.mktmpdir do |app_home|
      output, status = run_entrypoint(app_home: app_home, env: { "HOME" => app_home })

      assert_equal 0, status, output
      assert_match(/DROPPED HOME=#{Regexp.escape(app_home)}\b/, output)
    end
  end

  # The other side of that `id -u` check, and the one most deploys actually take: `web`,
  # dev, test and CI all start as uid 1000 already. There is nothing to drop, and this
  # block must not touch their environment or shell out to setpriv at all.
  test "a container started as the app user skips the privilege drop entirely" do
    Dir.mktmpdir do |stubs|
      write_stub stubs, "id", "#!/bin/bash\nif [ \"$1\" = \"-u\" ]; then echo 1000; else exit 0; fi\n"
      write_stub stubs, "setpriv", "#!/bin/bash\necho DROPPED\n"

      # This is the one test that runs past the drop into the rest of the script, so it
      # gets a PATH with no `claude`/`gh` and a cwd with no ./bin/ensure-playwright-browsers.
      # Otherwise the entrypoint's background update block really would install Chromium,
      # and IO.popen would sit on the open pipe until it finished.
      env = { "PATH" => "#{stubs}:/usr/bin:/bin", "HOME" => Dir.tmpdir }
      output = Dir.mktmpdir do |cwd|
        IO.popen(env, [ "bash", "-e", ENTRYPOINT, "echo", "ran" ], chdir: cwd, err: %i[child out], &:read)
      end

      assert_equal 0, $?.exitstatus, output
      refute_match(/DROPPED/, output, "it tried to drop privileges it does not have")
      assert_match(/ran/, output)
    end
  end

  # An image with no uid 1000 cannot be dropped into at all -- `setpriv --init-groups`
  # would fail on it too -- so guessing /home/rails would only trade the real diagnosis
  # for a confident-looking wrong one.
  test "it refuses when there is no uid 1000 to drop to" do
    output, status = run_entrypoint(app_home: "/unused", env: { "HOME" => "/root" }, passwd: nil)

    assert_equal 1, status, output
    assert_match(/no uid 1000 in \/etc\/passwd/, output)
    refute_match(/DROPPED/, output)
  end

  # The guard that keeps `ZIMMER_NESTED_DOCKER=1` from starting dockerd as REAL host root.
  # CI is not user-namespaced, which is what makes this runnable here rather than only
  # readable -- but say so out loud rather than passing vacuously if that ever changes.
  test "the entrypoint refuses nested Docker without a user namespace" do
    userns_base = File.read("/proc/self/uid_map")[/\A\s*0\s+(\d+)/, 1]
    skip "this container is user-namespaced (base #{userns_base}); the guard cannot fire here" unless userns_base == "0"

    Dir.mktmpdir do |app_home|
      output, status = run_entrypoint(
        app_home: app_home,
        env: { "HOME" => "/root", "ZIMMER_NESTED_DOCKER" => "1" }
      )

      assert_equal 1, status, output
      assert_match(/not user-namespaced/, output)
      refute_match(/DROPPED/, output, "it started dockerd as real host root")
    end
  end
end
