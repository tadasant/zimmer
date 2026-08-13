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
  #               instead of running the app
  #
  # Pass `passwd: nil` to make the lookup find no uid 1000 at all.
  def run_entrypoint(app_home:, env: {}, app_name: "rails", passwd: :present)
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
        while [[ "$1" == --* ]]; do shift; done
        if [ "$1" = "test" ]; then shift; test "$@"; exit $?; fi
        echo "DROPPED HOME=$HOME USER=$USER LOGNAME=$LOGNAME"
      SH

      # `-e` explicitly: the shebang carries it, and `bash <script>` does not honour a
      # shebang, so without it this would exercise a shell the container never runs.
      full_env = { "PATH" => "#{stubs}:#{ENV['PATH']}" }.merge(env)
      output = IO.popen(full_env, [ "bash", "-e", ENTRYPOINT, "true" ], err: %i[child out], &:read)
      [ output, $?.exitstatus ]
    end
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
