# frozen_string_literal: true

require "test_helper"
require "kamal"
require "erb"
require "yaml"

# A runtime's conversation lives on disk in the runtime's own home directory, not in
# Zimmer's database: Claude Code writes its transcripts under `~/.claude`, Codex writes
# its rollouts (plus `auth.json` and the thread store) under `CODEX_HOME`. `resume`
# resolves a conversation by that file. So a runtime home that is NOT a durable volume
# is destroyed by every Kamal deploy, and the next turn cannot resume — it starts a new
# conversation with no history.
#
# That failure is invisible where it matters. Zimmer keeps streaming, because
# `TranscriptPollerService` carries the stored transcript forward across the rotation, so
# the UI still shows the old messages. The session still lands in `needs_input`, because
# the fresh start exits 0 like any completed turn. The only visible symptom is an agent
# that has forgotten the conversation it is in the middle of — which reads as a bad
# answer, not as lost state.
#
# These tests pin the invariant that makes the failure impossible: every registered
# runtime's home directory is mounted as a durable named volume, in every deploy
# destination, for every role that runs agents. `registered_runtimes` is asserted against
# the table so a newly registered runtime fails here until its home is declared, rather
# than shipping with a home that silently evaporates on the next deploy.
class RuntimeHomeVolumesTest < ActiveSupport::TestCase
  include KamalConfigHelpers

  # Asserted against the MERGED config, never against a destination file on its own.
  # The durable volume list lives in `config/deploy.yml` and the destination files add
  # only what differs, so a destination file read alone shows no runtime home at all --
  # and, worse, a destination that restated `volume:` would REPLACE the shared list
  # rather than extend it, which is precisely the drift these assertions exist to catch.
  #
  # `DEPLOY_DESTINATIONS` is discovered from the deploy files (KamalConfigHelpers), for
  # the same reason the runtime axis is: a new destination must be covered the moment it
  # exists.

  # The container path each runtime keeps its conversation state in. Codex's is read
  # out of the image rather than hardcoded, because `CodexHome.path` resolves it from
  # `CODEX_HOME` at runtime and the image's `ENV` line is what actually sets that
  # value in production. Reading it here means a change to the image path fails this
  # test instead of silently unmounting the volume.
  # Pi's is read out of the image for the same reason Codex's is: `PiHome.path`
  # resolves it from `PI_CODING_AGENT_DIR` at runtime, and the image's `ENV` line
  # is what sets that value in production.
  #
  # Pi is worth a note, because it is the one runtime whose CONVERSATION does not
  # live in its home: PiRuntimeAdapter passes `--session-dir` pointing inside the
  # session's own clone, so a Pi transcript is durable by virtue of the clone
  # volume rather than this one. What lives here is Pi's credential and provider
  # state — `auth.json`, `models.json`, `settings.json`. Losing that on every
  # deploy is a milder failure than losing a conversation, but it is still one
  # nobody would see until a session could not authenticate, so the home is
  # mounted on the same terms as the other two.
  RUNTIME_HOMES = {
    "claude_code" => "/home/rails/.claude",
    "codex" => :codex_home_from_image,
    "pi" => :pi_home_from_image
  }.freeze

  test "every registered runtime has a home directory declared in this test's table" do
    assert_equal RuntimeRegistry.registered_runtimes.sort, RUNTIME_HOMES.keys.sort,
      "RUNTIME_HOMES must name a home directory for every runtime in RuntimeRegistry. " \
      "A runtime whose home is not listed here is not covered by the durability " \
      "assertions below, and its conversations would be destroyed on every deploy."
  end

  test "the image declares PI_CODING_AGENT_DIR so the deploy files have a path to mount" do
    assert_equal "/home/rails/.pi/agent", pi_home_from_image,
      "Dockerfile.base must set ENV PI_CODING_AGENT_DIR. Without it the Pi CLI falls back " \
      "to ~/.pi/agent by its own default and the mount below would target the wrong path."
  end

  test "the image declares CODEX_HOME so the deploy files have a path to mount" do
    assert_equal "/home/rails/.codex", codex_home_from_image,
      "Dockerfile.base must set ENV CODEX_HOME. Without it the Codex CLI falls back to " \
      "~/.codex by its own default and the mount below would target the wrong path."
  end

  DEPLOY_DESTINATIONS.each do |destination|
    %w[web worker].each do |role|
      RUNTIME_HOMES.each_key do |runtime|
        test "#{destination} mounts the #{runtime} runtime home durably for the #{role} role" do
          home = runtime_home(runtime)
          mounted = container_paths(destination, role)

          assert_includes mounted, home,
            "#{destination}'s #{role} role must mount #{home} (the #{runtime} runtime home) " \
            "as a durable volume. Without it the directory lives on the container layer, " \
            "every deploy destroys it, and the next turn resumes into a conversation that " \
            "no longer exists — the agent restarts from zero with no visible error."
        end

        test "#{destination} backs the #{runtime} runtime home with a named volume for the #{role} role" do
          home = runtime_home(runtime)
          source = volume_source(destination, role, home)

          assert source.present?, "#{destination}'s #{role} role must mount #{home}"
          refute source.start_with?("/"),
            "#{destination} mounts #{home} from host path #{source}. A runtime home must be a " \
            "NAMED volume: Docker seeds a named volume with the image directory's ownership " \
            "(uid 1000), while a bind mount of a missing host path comes up root-owned and the " \
            "runtime cannot write its rollouts at all."
        end
      end
    end

    # Both roles run agent processes (the worker runs sessions; the web role spawns them
    # too), so a home mounted for only one of them still loses state depending on which
    # container served the turn.
    test "#{destination} mounts the same runtime homes for web and worker" do
      web = container_paths(destination, "web") & runtime_homes
      worker = container_paths(destination, "worker") & runtime_homes

      assert_equal web.sort, worker.sort,
        "#{destination} must mount every runtime home for BOTH roles. A home visible to only " \
        "one container makes resume work or fail depending on which role handled the turn."
    end
  end

  # The list the assertions above walk is one list, in config/deploy.yml, and the reason
  # it can be is Kamal's merge: a destination that redeclares `volume:` REPLACES it. That
  # is invisible from either file, so pin it -- both destinations must inherit the shared
  # list rather than carry a copy that can drift out from under this test.
  test "no destination file declares its own volume list" do
    DEPLOY_DESTINATIONS.each do |destination|
      overlay = YAML.safe_load(
        ERB.new(Rails.root.join("config/deploy.#{destination}.yml").read).result, aliases: true
      )

      Array(overlay["servers"]).each do |role, spec|
        assert_nil spec&.dig("options", "volume"),
          "config/deploy.#{destination}.yml declares `volume:` for the #{role} role. Kamal's " \
          "destination merge REPLACES arrays, so that overrides the durable list in " \
          "config/deploy.yml and the next runtime home added there reaches other destinations " \
          "only. Add a destination-only mount through the top-level `volumes:` key instead."
      end
    end
  end

  private

  def runtime_homes = RUNTIME_HOMES.keys.map { |runtime| runtime_home(runtime) }

  # A nil home would make `assert_includes mounted, nil` pass against a volume entry
  # that has no container path — the one way these assertions could go quiet — so an
  # unresolvable home is an error here rather than a silently weakened test.
  def runtime_home(runtime)
    value = RUNTIME_HOMES.fetch(runtime)
    resolved = value.is_a?(Symbol) ? send(value) : value
    raise "Could not resolve the #{runtime} runtime home (#{value.inspect})" if resolved.blank?

    resolved
  end

  def codex_home_from_image
    Rails.root.join("Dockerfile.base").read[/^ENV\s+CODEX_HOME="?([^"\s]+)"?/, 1]
  end

  def pi_home_from_image
    Rails.root.join("Dockerfile.base").read[/^ENV\s+PI_CODING_AGENT_DIR="?([^"\s]+)"?/, 1]
  end

  # Kamal volume entries are `source:container_path[:opts]` strings, read off the role's
  # rendered `docker run` so the top-level `volumes:` key is included alongside the
  # role's own options.
  def container_paths(destination, role)
    kamal_volumes(destination, role).map { |entry| entry.split(":")[1] }
  end

  def volume_source(destination, role, container_path)
    entry = kamal_volumes(destination, role).find { |v| v.split(":")[1] == container_path }
    entry&.split(":")&.first
  end
end
