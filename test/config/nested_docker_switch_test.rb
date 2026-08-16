# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# Nested Docker is three settings that are only safe together: the sysbox runtime (which
# gives the container a user namespace), starting as container-root (so the entrypoint can
# bring up dockerd), and the env var the entrypoint reads. Any two without the third is a
# failure mode rather than a degraded mode -- most sharply runtime-without-user, which
# starts a container whose root is REAL host root and hands every agent session the host.
#
# So one variable arms all three, and these assertions are what keeps that true. They also
# pin each destination's DEFAULT, which is the part that differs: staging deploys armed,
# production deploys off. Staging's droplet is provisioned for sysbox and runs nobody
# else's work, so it is where the arrangement gets proven; production is where agent
# sessions actually live, so it gets the switch only once staging has run on it.
class NestedDockerSwitchTest < ActiveSupport::TestCase
  # destination => whether an unset ZIMMER_NESTED_DOCKER deploys nested Docker armed.
  DEFAULTS = { "production" => false, "staging" => true }.freeze
  DESTINATIONS = DEFAULTS.keys.freeze

  RENDER_ENV = {
    "PRODUCTION_HOST" => "198.51.100.10",
    "STAGING_HOST" => "198.51.100.11",
    "PRODUCTION_DB_HOST" => "managed-db.example.internal"
  }.freeze

  def deploy_config(destination, nested: nil)
    path = Rails.root.join("config/deploy.#{destination}.yml")
    overrides = RENDER_ENV.merge(nested ? { "ZIMMER_NESTED_DOCKER" => nested } : {})
    keys = overrides.keys | [ "ZIMMER_NESTED_DOCKER" ]

    previous = ENV.to_h.slice(*keys)
    keys.each { |k| ENV.delete(k) }
    ENV.update(overrides)
    YAML.safe_load(ERB.new(path.read).result, aliases: true)
  ensure
    keys.each { |k| previous.key?(k) ? ENV[k] = previous[k] : ENV.delete(k) }
  end

  # All three armed, or none of them. Asserted as one unit because that is the actual
  # invariant -- the interesting failure is a config that arms two of the three.
  def assert_armed(config)
    options = config.dig("servers", "worker", "options")

    assert_equal "sysbox-runc", options["runtime"],
      "without the sysbox runtime the container has no user namespace"
    assert_equal "0:0", options["user"],
      "without container-root the entrypoint cannot start dockerd"
    assert_equal "1", config.dig("env", "clear", "ZIMMER_NESTED_DOCKER"),
      "without the env var the entrypoint never starts dockerd"
  end

  def assert_disarmed(config)
    options = config.dig("servers", "worker", "options")

    assert_equal "runc", options["runtime"]
    assert_equal "1000:1000", options["user"]
    assert_equal "0", config.dig("env", "clear", "ZIMMER_NESTED_DOCKER")
  end

  DESTINATIONS.each do |destination|
    armed_by_default = DEFAULTS.fetch(destination)

    test "#{destination} defaults to nested Docker #{armed_by_default ? 'ARMED' : 'OFF'}" do
      config = deploy_config(destination)

      armed_by_default ? assert_armed(config) : assert_disarmed(config)
    end

    test "#{destination}'s worker arms all three settings together when the switch is on" do
      assert_armed deploy_config(destination, nested: "1")
    end

    # The rollback. A destination that defaults to armed still has to be able to deploy
    # under plain runc -- that is the one move available if a sysbox deploy misbehaves,
    # or if the droplet is replaced by one without sysbox on it.
    test "#{destination}'s worker disarms all three settings together when the switch is off" do
      assert_disarmed deploy_config(destination, nested: "0")
    end

    # YAML reads a bare `0:0` as a sexagesimal integer and yields 0 -- uid 0 with the
    # image's default gid. Close enough to look right, and wrong in a way nothing reports.
    test "#{destination}'s worker user stays a string rather than a sexagesimal integer" do
      user = deploy_config(destination, nested: "1").dig("servers", "worker", "options", "user")

      assert_kind_of String, user, "user parsed as #{user.class} (#{user.inspect}); quote it"
    end

    # The host socket is what nested Docker exists to avoid needing. Mounting it back would
    # reintroduce exactly the root-equivalent exposure, and silently.
    test "#{destination}'s worker does not mount the host Docker socket" do
      %w[0 1].each do |state|
        volumes = Array(deploy_config(destination, nested: state).dig("servers", "worker", "options", "volume"))

        refute volumes.any? { |v| v.include?("/var/run/docker.sock") },
          "the worker mounts the host Docker socket (switch=#{state}); nested Docker exists so it does not have to"
      end
    end

    # web serves HTTP and runs no agent sessions. It should never gain either half.
    test "#{destination} never extends nested Docker to the web role" do
      web = deploy_config(destination, nested: "1").dig("servers", "web", "options")

      refute_equal "sysbox-runc", web["runtime"]
      refute_equal "0:0", web["user"]
      refute Array(web["volume"]).any? { |v| v.include?("/var/run/docker.sock") }
    end
  end

  # Staging's worker is the only role running work whose peak allocation nothing in this
  # config knows in advance, on a 4 GB droplet with no swap. Uncapped, one such allocation
  # is a GLOBAL OOM: the kernel takes victims host-wide, sshd and Caddy lose their working
  # set, and the droplet stops answering SSH and HTTPS while the app itself is fine. The
  # cap is what keeps the kill inside the worker's cgroup, and it is invisible in every
  # green check -- so pin it here, where dropping it fails loudly.
  #
  # Asserted under both switch positions on purpose. The cap is not conditional on the switch
  # today, and that is the property being pinned: arming nested Docker puts an inner dockerd and
  # the session's containers inside this same cgroup, which is the change most likely to tempt
  # someone into making the cap conditional -- or into dropping it to make room.
  test "staging's worker is capped so a runaway allocation cannot take the droplet down" do
    %w[0 1].each do |state|
      memory = deploy_config("staging", nested: state).dig("servers", "worker", "options", "memory")

      assert_equal "2g", memory,
        "staging's worker memory cap is #{memory.inspect} (switch=#{state}); uncapped, a runaway " \
        "job takes the whole droplet down with it, sshd included"
    end
  end

  # Arming the switch sets `user: "0:0"`, and Docker derives HOME from --user: uid 0 resolves
  # to /root. That becomes the CONTAINER's environment, which is what PID 1 (docker-init --
  # every role sets `init: true`) and every `docker exec -u 1000` inherit, none of which ever
  # run bin/docker-entrypoint. At uid 1000 /root is mode 0700 and root-owned, so libpq's probe
  # of $HOME/.postgresql/postgresql.crt gets EACCES -- fatal, unlike the ENOENT it tolerates --
  # and ~/.claude, ~/.config/gh, ~/.local and ~/.zimmer are absent.
  #
  # Pinning HOME in the image is what makes it a property of the app user rather than of the
  # uid the container starts as. Asserted here rather than in a Dockerfile-shaped test because
  # this is the file that owns the `user: "0:0"` decision that creates the need for it.
  #
  # A predicate rather than assert_match on the file: matching a regexp against the whole
  # Dockerfile dumps all 120 lines of it into the failure message, which buries the sentence
  # that says what to do about it.
  def image_pins_home?
    Rails.root.join("Dockerfile").read.match?(/^ENV HOME=\/home\/rails$/)
  end

  # Both halves together, per destination, because the pairing is the invariant: a role that
  # starts as container-root against an image that does not pin HOME is what produces /root.
  # Either one alone is harmless. Production matters as much as staging here -- it resolves
  # the same switch to the same `user: "0:0"`, so it carries the same latent bug the moment
  # ZIMMER_NESTED_DOCKER=1 reaches it.
  DESTINATIONS.each do |destination|
    test "#{destination}'s worker starts as container-root only against an image that pins HOME" do
      user = deploy_config(destination, nested: "1").dig("servers", "worker", "options", "user")

      assert_equal "0:0", user, "guard assumption changed: arming no longer starts the worker as root"
      assert image_pins_home?,
        "#{destination}'s worker starts as uid 0 but the image no longer pins ENV HOME=/home/rails, " \
        "so Docker derives HOME=/root from --user. At uid 1000 that is untraversable: libpq's TLS " \
        "probe gets EACCES and ~/.claude, ~/.config/gh, ~/.local, ~/.zimmer are absent."
    end
  end

  # The entrypoint's own fixup is the other half, and the stronger one: it covers the app
  # process and refuses to boot when uid 1000 cannot use the directory, which no image ENV
  # can check. The image ENV does not replace it -- losing either reopens the failure.
  test "the entrypoint still derives HOME from /etc/passwd and proves it usable" do
    script = Rails.root.join("bin/docker-entrypoint").read

    assert_match(/export HOME=/, script,
      "the entrypoint no longer sets HOME; the app process would keep whatever --user derived")
    assert_match(/setpriv --reuid=1000 --regid=1000 --init-groups test -x "\$HOME" -a -w "\$HOME"/, script,
      "the entrypoint no longer proves HOME usable at uid 1000 before dropping to it")
  end

  # The entrypoint is the piece that actually decides whether dockerd starts, and its guard
  # is the only thing standing between "misconfigured host" and "every session has host
  # root". Assert the guard exists rather than trusting a comment.
  test "the entrypoint refuses to start dockerd without a user namespace" do
    script = Rails.root.join("bin/docker-entrypoint").read

    assert_match(/uid_map/, script, "the entrypoint no longer checks for a user namespace")
    assert_match(/ZIMMER_NESTED_DOCKER/, script)
    assert_match(/setpriv --reuid=1000 --regid=1000/, script,
      "the entrypoint no longer drops back to the app user; the app would keep running as root")
  end

  # dockerd's socket is root-owned unless it is told otherwise, and everything after the
  # privilege drop runs as 1000. Without the group the drop produces a working daemon that
  # the app cannot talk to.
  test "the nested daemon hands its socket to the group the app runs as" do
    assert_match(/dockerd --group 1000/, Rails.root.join("bin/docker-entrypoint").read)
  end
end
