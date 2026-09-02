# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

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
  #               scope is assertable without faking what it actually finds.
  #               `find_emits:` instead makes it print a fixed NUL-separated list,
  #               which is the only way to assert what the sweep DOES with a hit on
  #               a machine whose own uid is 1000 and which therefore cannot create
  #               one.
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
  #               `sleep_succeeds_once:` lets one iteration through instead. Note
  #               that this stub is also on PATH for the dockerd wait loop, where a
  #               failing `sleep` is the last command in the body and would abort the
  #               script under `-e`; no test reaches that loop today, because the
  #               user-namespace guard exits first.
  #
  # Pass `passwd: nil` to make the lookup find no uid 1000 at all.
  #
  # `cgroup_fs_root:` points the delegation block (which the entrypoint derives from
  # ZIMMER_SESSION_CGROUP_ROOT's parent) at a directory the test controls. It defaults to
  # one inside the stubs tmpdir that has no `cgroup.controllers`, so the block returns
  # immediately -- which is both what a machine without cgroup v2 does and what keeps every
  # other test in this file away from the runner's real /sys/fs/cgroup.
  def run_entrypoint(app_home:, env: {}, app_name: "rails", passwd: :present, sleep_succeeds_once: false,
    find_emits: nil, cgroup_fs_root: nil)
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

      write_stub stubs, "find", if find_emits
        <<~SH
          #!/bin/bash
          echo "FIND-ARGV $*" >> "#{stub_log}"
          printf '%s\\0' #{find_emits.map { |p| "'#{p}'" }.join(' ')}
        SH
      else
        <<~SH
          #!/bin/bash
          echo "FIND-ARGV $*" >> "#{stub_log}"
          exec #{real_find} "$@"
        SH
      end

      write_stub stubs, "sleep", sleep_succeeds_once ? <<~SH : "#!/bin/bash\nexit 1\n"
        #!/bin/bash
        marker="$(dirname "$0")/.slept"
        if [ -e "$marker" ]; then exit 1; fi
        : > "$marker"
        exit 0
      SH

      # `-e` explicitly: the shebang carries it, and `bash <script>` does not honour a
      # shebang, so without it this would exercise a shell the container never runs.
      cgroup_fs_root ||= FileUtils.mkdir_p(File.join(stubs, "cgroupfs")).first
      full_env = {
        "PATH" => "#{stubs}:#{ENV['PATH']}",
        "ZIMMER_SESSION_CGROUP_ROOT" => File.join(cgroup_fs_root, "zimmer.sessions")
      }.merge(env)
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

      # Skip the flags that precede the operands (`-H`), then take the operands.
      roots = sweep.split[1..].drop_while { |a| !a.start_with?("/") }.take_while { |a| a.start_with?("/") }
      assert_equal [ "#{app_home}/.claude", "#{app_home}/.config/gh", "#{app_home}/.zimmer" ], roots.sort,
        "the sweep must cover the mounted volumes, and only those"
      refute_includes roots, app_home, "sweeping all of $HOME would rewrite container-layer state"
      refute_includes roots, "#{app_home}/.cache"

      # -H: `[ -d ]` above follows a symlinked root, so find must too, or such a root
      # is swept as a single inode while still logging as though it had run.
      assert_match(/\AFIND-ARGV -H /, sweep)
      # -xdev: a dev stack's own container filesystems can appear under these paths,
      # and they are not ours to rewrite.
      assert_match(/ -xdev /, sweep)
      assert_match(/ ! -uid 1000 /, sweep)
    end
  end

  # The behaviour itself, and the half that must not depend on the machine: whatever the
  # sweep finds is handed to uid 1000.
  #
  # `find_emits:` fakes the hits rather than the predicate, because a suite running AS uid
  # 1000 cannot create a file that is not owned by uid 1000, and without this the chown
  # would be asserted nowhere -- deleting it from the entrypoint would leave this file
  # green. The predicate itself is covered by the scope test above, which runs the real
  # `find`.
  test "the reclaim chowns every path the sweep turns up, whatever uid runs the suite" do
    Dir.mktmpdir do |app_home|
      FileUtils.mkdir_p("#{app_home}/.claude")
      hits = [ "#{app_home}/.claude/one.jsonl", "#{app_home}/.claude/two.jsonl" ]

      output, status, stubs = run_entrypoint(
        app_home: app_home, env: { "HOME" => "/root" }, find_emits: hits
      )
      assert_equal 0, status, output

      chowns = stubs.lines.grep(/^CHOWN-ARGV /).map(&:strip)
      assert_equal 1, chowns.length,
        "expected the batch to reach chown in one invocation, not one call per file, got:\n#{output}"
      assert_equal "CHOWN-ARGV -h 1000:1000 #{hits[0]} #{hits[1]}", chowns.first,
        "-h so a symlink is retargeted rather than whatever it points at"
      assert_match(/Reclaimed 2 path\(s\) not owned by uid 1000/, output,
        "a silent repair is one nobody can confirm ran")
    end
  end

  # The other direction: a volume that is already correct must not be churned. Only
  # assertable when the suite runs as the app user, since that is what makes the files it
  # creates match the predicate's exclusion.
  test "the reclaim leaves files already owned by uid 1000 alone" do
    skip "only uid 1000 can create files this sweep is supposed to skip" unless Process.uid == 1000

    Dir.mktmpdir do |app_home|
      FileUtils.mkdir_p("#{app_home}/.claude/projects/-app")
      File.write("#{app_home}/.claude/projects/-app/session.jsonl", "{}\n")

      output, status, stubs = run_entrypoint(app_home: app_home, env: { "HOME" => "/root" })

      assert_equal 0, status, output
      assert_empty stubs.lines.grep(/^CHOWN-ARGV /), "it rewrote files that were already correct"
      refute_match(/Reclaimed/, output)
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

  # --- per-session cgroup delegation (tadasant/zimmer#815) -------------------
  #
  # Only root can create a cgroup and enable a controller on it, so this setup has to
  # happen in the entrypoint -- and if any step of it is wrong the app silently runs every
  # session unbounded, which is exactly the state #815 was filed about. These tests run the
  # block against a directory shaped like a cgroup v2 root; what they cannot cover is the
  # kernel's own enforcement (CI has no writable cgroupfs), which is verified on staging.

  # A directory that looks enough like a cgroup v2 root for the block to proceed.
  def fake_cgroupfs(dir, controllers: "cpuset cpu io memory pids", subtree_control: "memory")
    File.write(File.join(dir, "cgroup.controllers"), "#{controllers}\n")
    File.write(File.join(dir, "cgroup.subtree_control"), "#{subtree_control}\n")
    dir
  end

  test "the entrypoint delegates a session cgroup parent to uid 1000" do
    Dir.mktmpdir do |app_home|
      Dir.mktmpdir do |cgroupfs|
        fake_cgroupfs(cgroupfs)
        output, status, stub_log = run_entrypoint(
          app_home: app_home, env: { "HOME" => "/root" }, cgroup_fs_root: cgroupfs
        )
        parent = File.join(cgroupfs, "zimmer.sessions")

        assert_equal 0, status, output
        assert File.directory?(parent), "the delegated parent was not created: #{output}"
        assert_match(/CHOWN-ARGV .*\b1000\b.*#{Regexp.escape(parent)}\b/, stub_log,
          "without the chown, uid 1000 cannot create a session cgroup and every session " \
          "runs unbounded")
      end
    end
  end

  # The `app` child is what makes the delegated parent the common ancestor of every later
  # migration. Without it, uid 1000 can create session cgroups and then not move anything
  # into them -- a bound that exists and never applies, which is worse than none because it
  # looks like it works.
  test "the entrypoint moves the app into a sibling under the delegated parent" do
    Dir.mktmpdir do |app_home|
      Dir.mktmpdir do |cgroupfs|
        fake_cgroupfs(cgroupfs)
        output, status = run_entrypoint(
          app_home: app_home, env: { "HOME" => "/root" }, cgroup_fs_root: cgroupfs
        )
        app_procs = File.join(cgroupfs, "zimmer.sessions", "app", "cgroup.procs")

        assert_equal 0, status, output
        assert File.exist?(app_procs), "the app cgroup was never populated: #{output}"
        assert_match(/\A\d+\n?\z/, File.read(app_procs),
          "cgroup.procs takes the pid of the process joining it")
        assert_equal "+memory\n", File.read(File.join(cgroupfs, "zimmer.sessions", "cgroup.subtree_control")),
          "without +memory on the parent, a session cgroup has no memory.max to set"
      end
    end
  end

  # Every deployment that is not the sysbox worker: read-only cgroupfs under plain runc, no
  # cgroup v2 at all on a dev Mac. The bound is a guardrail, and a guardrail that refuses to
  # boot the container is a worse outage than the one it prevents.
  test "a container with no memory controller boots normally without a session cgroup" do
    Dir.mktmpdir do |app_home|
      Dir.mktmpdir do |cgroupfs|
        fake_cgroupfs(cgroupfs, controllers: "cpuset cpu io pids")
        output, status = run_entrypoint(
          app_home: app_home, env: { "HOME" => "/root" }, cgroup_fs_root: cgroupfs
        )

        assert_equal 0, status, output
        assert_match(/DROPPED HOME=/, output, "the handover must still happen")
        refute File.exist?(File.join(cgroupfs, "zimmer.sessions")),
          "nothing should be created when the kernel cannot enforce a memory bound"
      end
    end
  end

  # A silent skip is the worst outcome available here: the app runs every session
  # unbounded -- the exact state #815 is about -- with nothing in the boot log to say why.
  test "the entrypoint says which step turned per-session memory bounds off" do
    Dir.mktmpdir do |app_home|
      Dir.mktmpdir do |cgroupfs|
        fake_cgroupfs(cgroupfs, controllers: "cpuset cpu io pids")
        output, = run_entrypoint(
          app_home: app_home, env: { "HOME" => "/root" }, cgroup_fs_root: cgroupfs
        )

        assert_match(/Per-session memory bounds are OFF: the memory controller is not available/, output)
        assert_match(/run unbounded/, output, "the consequence has to be in the message, not just the cause")
      end
    end
  end

  # The one step that can fail on a real, populated cgroup root: cgroup v2 refuses to
  # enable a controller in subtree_control while the cgroup holds processes directly. The
  # happy-path tests never reach this branch, because their fixture already lists memory.
  test "the entrypoint enables the memory controller when the root does not already offer it" do
    Dir.mktmpdir do |app_home|
      Dir.mktmpdir do |cgroupfs|
        fake_cgroupfs(cgroupfs, subtree_control: "")
        output, status = run_entrypoint(
          app_home: app_home, env: { "HOME" => "/root" }, cgroup_fs_root: cgroupfs
        )

        assert_equal 0, status, output
        assert_equal "+memory\n", File.read(File.join(cgroupfs, "cgroup.subtree_control"))
        assert File.directory?(File.join(cgroupfs, "zimmer.sessions", "app")), output
      end
    end
  end

  # The ordering that keeps a half-delegated state unreachable. The chown is what
  # SessionMemoryCgroup.available? reads, so it must come last: a parent uid 1000 can
  # create cgroups in but never migrate into is worse than no parent at all -- the app
  # would wrap every spawn, litter a cgroup per session, and report zero usage forever.
  test "the delegating chown happens only after the app is in its cgroup" do
    Dir.mktmpdir do |app_home|
      Dir.mktmpdir do |cgroupfs|
        fake_cgroupfs(cgroupfs)
        # A file where the app cgroup's directory needs to be, so `mkdir -p .../app`
        # fails and the move-in can never happen.
        FileUtils.mkdir_p(File.join(cgroupfs, "zimmer.sessions"))
        File.write(File.join(cgroupfs, "zimmer.sessions", "app"), "")

        output, status, stub_log = run_entrypoint(
          app_home: app_home, env: { "HOME" => "/root" }, cgroup_fs_root: cgroupfs
        )

        assert_equal 0, status, output
        assert_match(/Per-session memory bounds are OFF/, output)
        refute_match(/CHOWN-ARGV .*zimmer\.sessions/, stub_log,
          "delegating a parent the app never got into leaves a bound that can never apply")
      end
    end
  end
end
