# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The privilege drop `bin/docker-entrypoint` performs when the container starts as root.
#
# Nested Docker runs the worker as `user: "0:0"`, Docker derives HOME from `--user`, and
# `setpriv` changes credentials without touching the environment -- so the app can end up
# running as uid 1000 with HOME=/root, a directory it cannot read. That fails every libpq
# TLS connection with EACCES, which means a worker that boots, logs, and claims no jobs
# while looking entirely healthy. docs/operate/nested-docker.md has the full account.
#
# Assertions that read the entrypoint as text cannot catch that, so these RUN it, with
# `id`, `getent` and `setpriv` stubbed on PATH, and assert the environment and credentials
# it actually hands over. Nothing here needs root.
#
# What they deliberately do not cover is the real thing -- a worker under `sysbox-runc`
# draining a real job -- because CI has neither the runtime nor a user namespace. That is
# verified on staging.
class DockerEntrypointPrivilegeDropTest < ActiveSupport::TestCase
  ENTRYPOINT = Rails.root.join("bin/docker-entrypoint").to_s

  # Stubs the three commands the root branch shells out to, so it can run unprivileged:
  #
  #   id       -- claim to be uid 0, which is what puts us on the branch at all
  #   getent   -- answer the passwd lookup with a home we control, so the assertion does
  #               not depend on whether /home/rails exists on the CI runner
  #   setpriv  -- stand in for both calls the entrypoint makes: the `test -w` probe (run
  #               for real, since that IS the assertion under test) and the final re-exec,
  #               which prints the environment instead of running the app
  def run_entrypoint(app_home:, env: {}, app_name: "rails")
    Dir.mktmpdir do |stubs|
      write_stub stubs, "id", <<~SH
        #!/bin/bash
        if [ "$1" = "-u" ]; then echo 0; else exit 0; fi
      SH

      write_stub stubs, "getent", <<~SH
        #!/bin/bash
        echo "#{app_name}:x:1000:1000::#{app_home}:/bin/bash"
      SH

      write_stub stubs, "setpriv", <<~SH
        #!/bin/bash
        flags=""
        while [[ "$1" == --* ]]; do flags="$flags $1"; shift; done
        if [ "$1" = "test" ]; then shift; test "$@"; exit $?; fi
        echo "DROPPED flags=$flags HOME=$HOME USER=$USER LOGNAME=$LOGNAME"
      SH

      # ZIMMER_NESTED_DOCKER is pinned OFF rather than merely left unset. It is in
      # `env: clear:` for the whole app, so every process in the deployed worker sees
      # it -- including an agent session running this suite, where inheriting a `1`
      # would send these cases into the dockerd branch and test something else.
      #
      # `-e` explicitly: the shebang carries it, and `bash <script>` does not honour a
      # shebang, so without it this would exercise a shell the container never runs.
      full_env = { "PATH" => "#{stubs}:#{ENV['PATH']}", "ZIMMER_NESTED_DOCKER" => "0" }.merge(env)
      output = IO.popen(full_env, [ "bash", "-e", ENTRYPOINT, "true" ], err: %i[child out], &:read)
      [ output, $?.exitstatus ]
    end
  end

  def write_stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  # The regression itself: an entrypoint that hands the environment over untouched
  # asserts HOME=/root here and fails.
  test "the privilege drop rewrites a root HOME to the app user's" do
    Dir.mktmpdir do |app_home|
      output, status = run_entrypoint(app_home: app_home, env: { "HOME" => "/root" })

      assert_equal 0, status, output
      assert_match(/HOME=#{Regexp.escape(app_home)}\b/, output,
        "the app would run as uid 1000 with HOME=/root, which it cannot read -- libpq " \
        "fails every TLS connection with EACCES and the worker claims no jobs")
      refute_match(%r{HOME=/root}, output)
    end
  end

  # The drop itself, not just the environment it carries. Without this the stub would
  # accept `--reuid=0` and the file would still be green.
  test "the handover drops to uid 1000 and initialises its groups" do
    Dir.mktmpdir do |app_home|
      output, = run_entrypoint(app_home: app_home, env: { "HOME" => "/root" })

      assert_match(/flags=.*--reuid=1000\b/, output)
      assert_match(/flags=.*--regid=1000\b/, output)
      assert_match(/flags=.*--init-groups\b/, output,
        "without it the process keeps only gid 1000 and loses its supplementary groups")
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
  test "the entrypoint refuses to drop into a HOME that does not exist" do
    output, status = run_entrypoint(
      app_home: "/nonexistent-#{SecureRandom.hex(6)}",
      env: { "HOME" => "/root" }
    )

    assert_equal 1, status, "expected the entrypoint to refuse, got:\n#{output}"
    assert_match(/Refusing to start/, output)
    refute_match(/DROPPED/, output, "it handed over anyway")
  end

  # The shape that actually caused the outage: the directory is there, and the user it
  # is handing over to cannot get into it. That is EACCES, not ENOENT, and the two
  # reach the probe by different routes.
  test "the entrypoint refuses to drop into a HOME the app user cannot enter" do
    skip "root can read and write any directory, so the probe cannot fail here" if Process.uid.zero?

    Dir.mktmpdir do |app_home|
      File.chmod(0o000, app_home)

      output, status = run_entrypoint(app_home: app_home, env: { "HOME" => "/root" })

      assert_equal 1, status, "expected the entrypoint to refuse, got:\n#{output}"
      assert_match(/not readable, writable and traversable/, output)
      refute_match(/DROPPED/, output, "it handed over anyway")
    ensure
      File.chmod(0o700, app_home)
    end
  end

  # The app user's own environment is already correct; the drop must not disturb it.
  test "a container already started with the app user's HOME is unaffected" do
    Dir.mktmpdir do |app_home|
      output, status = run_entrypoint(app_home: app_home, env: { "HOME" => app_home })

      assert_equal 0, status, output
      assert_match(/DROPPED .*HOME=#{Regexp.escape(app_home)}\b/, output)
    end
  end

  # The guard that keeps `ZIMMER_NESTED_DOCKER=1` from starting dockerd as REAL host root.
  # CI is not user-namespaced, which is what makes this runnable here rather than only
  # readable -- but say so out loud rather than passing vacuously if that ever changes.
  test "the entrypoint refuses nested Docker without a user namespace" do
    skip "no /proc/self/uid_map; the guard reads it and cannot be exercised here" unless File.exist?("/proc/self/uid_map")

    userns_base = File.read("/proc/self/uid_map")[/\A\s*0\s+(\d+)/, 1]
    unless userns_base == "0"
      skip "the guard only fires without a user namespace; uid_map base here is " \
           "#{userns_base || 'unreadable'}"
    end

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
