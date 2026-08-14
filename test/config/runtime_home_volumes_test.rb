# frozen_string_literal: true

require "test_helper"
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
  # Discovered rather than listed, for the same reason the runtime axis is: a new
  # deploy destination must be covered the moment it exists. `config/deploy.yml` is
  # the merged base and declares no `volume:` key of its own, so the glob's exclusion
  # of it (it has no `.<env>.` segment) is correct rather than incidental. Roles come
  # from each file's own `servers`, so a third role is covered too.
  DEPLOY_FILES = Rails.root.glob("config/deploy.*.yml").to_h do |path|
    file = path.relative_path_from(Rails.root).to_s
    [ file, YAML.safe_load(ERB.new(path.read).result, aliases: true).fetch("servers").keys ]
  end.freeze

  # The container path each runtime keeps its conversation state in. Codex's is read
  # out of the image rather than hardcoded, because `CodexHome.path` resolves it from
  # `CODEX_HOME` at runtime and the image's `ENV` line is what actually sets that
  # value in production. Reading it here means a change to the image path fails this
  # test instead of silently unmounting the volume.
  RUNTIME_HOMES = {
    "claude_code" => "/home/rails/.claude",
    "codex" => :codex_home_from_image
  }.freeze

  test "every registered runtime has a home directory declared in this test's table" do
    assert_equal RuntimeRegistry.registered_runtimes.sort, RUNTIME_HOMES.keys.sort,
      "RUNTIME_HOMES must name a home directory for every runtime in RuntimeRegistry. " \
      "A runtime whose home is not listed here is not covered by the durability " \
      "assertions below, and its conversations would be destroyed on every deploy."
  end

  test "the image declares CODEX_HOME so the deploy files have a path to mount" do
    assert_equal "/home/rails/.codex", codex_home_from_image,
      "Dockerfile.base must set ENV CODEX_HOME. Without it the Codex CLI falls back to " \
      "~/.codex by its own default and the mount below would target the wrong path."
  end

  DEPLOY_FILES.each do |deploy_file, roles|
    roles.each do |role|
      RUNTIME_HOMES.each_key do |runtime|
        test "#{deploy_file} mounts the #{runtime} runtime home durably for the #{role} role" do
          home = runtime_home(runtime)
          mounted = container_paths(deploy_file, role)

          assert_includes mounted, home,
            "#{deploy_file}'s #{role} role must mount #{home} (the #{runtime} runtime home) " \
            "as a durable volume. Without it the directory lives on the container layer, " \
            "every deploy destroys it, and the next turn resumes into a conversation that " \
            "no longer exists — the agent restarts from zero with no visible error."
        end

        test "#{deploy_file} backs the #{runtime} runtime home with a named volume for the #{role} role" do
          home = runtime_home(runtime)
          source = volume_source(deploy_file, role, home)

          assert source.present?, "#{deploy_file}'s #{role} role must mount #{home}"
          refute source.start_with?("/"),
            "#{deploy_file} mounts #{home} from host path #{source}. A runtime home must be a " \
            "NAMED volume: Docker seeds a named volume with the image directory's ownership " \
            "(uid 1000), while a bind mount of a missing host path comes up root-owned and the " \
            "runtime cannot write its rollouts at all."
        end
      end
    end
  end

  # Both roles run agent processes (the worker runs sessions; the web role spawns them
  # too), so a home mounted for only one of them still loses state depending on which
  # container served the turn.
  DEPLOY_FILES.each_key do |deploy_file|
    test "#{deploy_file} mounts the same runtime homes for web and worker" do
      web = container_paths(deploy_file, "web") & runtime_homes
      worker = container_paths(deploy_file, "worker") & runtime_homes

      assert_equal web.sort, worker.sort,
        "#{deploy_file} must mount every runtime home for BOTH roles. A home visible to only " \
        "one container makes resume work or fail depending on which role handled the turn."
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

  # Kamal volume entries are `source:container_path[:opts]` strings.
  def volumes(deploy_file, role)
    Array(render(deploy_file).dig("servers", role, "options", "volume"))
  end

  def container_paths(deploy_file, role)
    volumes(deploy_file, role).map { |entry| entry.split(":")[1] }
  end

  def volume_source(deploy_file, role, container_path)
    entry = volumes(deploy_file, role).find { |v| v.split(":")[1] == container_path }
    entry&.split(":")&.first
  end

  # The deploy files are ERB (hosts come from ENV at deploy time). Rendering with the
  # vars unset yields nils, which is fine -- nothing read here is interpolated.
  def render(deploy_file)
    YAML.safe_load(ERB.new(Rails.root.join(deploy_file).read).result, aliases: true)
  end
end
