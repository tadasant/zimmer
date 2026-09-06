# frozen_string_literal: true

require "test_helper"
require "kamal"

# `config/deploy.yml` holds what both destinations share -- `init: true`, the durable
# volume list, the worker's `cmd`/`proxy` -- and each `config/deploy.<dest>.yml` holds
# only what differs. That split is what stops a mount from being added to one
# destination and forgotten in the other, which is the drift `678f768` had to fix for
# CODEX_HOME: the runtime home lived on the container layer, every deploy destroyed it,
# and the next `resume` failed with "no rollout found".
#
# The split is only safe because of how Kamal merges the two files, and that is the part
# no single file shows: `load_config_files` folds them with ActiveSupport's `deep_merge!`,
# which recurses into HASHES and REPLACES ARRAYS. So a destination that restates
# `volume:` silently overrides the shared list instead of adding to it, and a
# destination-only mount has to go through the top-level `volumes:` key -- which Kamal
# appends to every app role's `docker run`.
#
# These tests assert the MERGED result, role by role. `runtime_home_volumes_test.rb`
# covers the runtime homes on the same footing (driven off `RuntimeRegistry`), and
# `nested_docker_switch_test.rb` covers the runtime/user/env switch; what is here is the
# rest of what the base file now owns.
class KamalDeployConfigTest < ActiveSupport::TestCase
  include KamalConfigHelpers

  # Durable mounts that are not a runtime home, so nothing else asserts them.
  SHARED_VOLUMES = %w[
    zimmer_data:/home/rails/.zimmer
    gh_config:/home/rails/.config/gh
    claude_local:/home/rails/.local
  ].freeze

  # The production catalog and its encrypted credentials, delivered to the host by
  # artifacts-sync-prod and bind-mounted read-only. Declared once, through the top-level
  # `volumes:` key, so they reach both roles without displacing the shared list.
  PRODUCTION_VOLUMES = %w[
    /opt/zimmer/catalog:/rails/catalog:ro
    /opt/zimmer/credentials:/rails/config/credentials:ro
  ].freeze

  DEPLOY_DESTINATIONS.each do |destination|
    %w[web worker].each do |role|
      test "#{destination}'s #{role} role inherits the shared durable volumes" do
        volumes = kamal_volumes(destination, role)

        SHARED_VOLUMES.each do |volume|
          assert_includes volumes, volume,
            "#{destination}/#{role} is missing #{volume}. If config/deploy.#{destination}.yml " \
            "declares its own `volume:` list it REPLACES the one in config/deploy.yml -- add a " \
            "destination-only mount through the top-level `volumes:` key instead."
        end
      end

      # tini-style PID 1, so agent-spawned grandchildren (gh, git, node, chrome, claude)
      # are reaped instead of piling up as zombies.
      test "#{destination}'s #{role} role runs under an init process" do
        assert_includes kamal_docker_run(destination, role), "--init"
      end
    end

    test "#{destination} runs the worker as an unproxied GoodJob process" do
      worker = kamal_config(destination).role(:worker)

      assert_equal "bundle exec good_job start", worker.cmd,
        "production.rb sets good_job.execution_mode = :external, so nothing runs jobs without this."
      assert_not worker.running_proxy?,
        "The worker must not be behind kamal-proxy; only web answers the health gate."
    end

    # The AGENT_ORCHESTRATOR_* -> ZIMMER_* rename finished on 2026-07-12 (#134), and the
    # dual-set names it carried were retired in #526. Nothing resolves them:
    # AppUrl reads ZIMMER_*_BASE_URL and SelfSessionInjector#api_key_var reads
    # ZIMMER_*_API_KEY. Re-adding one injects a live secret into every container for a
    # reader that does not exist.
    test "#{destination} injects no legacy AGENT_ORCHESTRATOR_* name" do
      kamal_config(destination).roles.each do |role|
        env = role.env(role.hosts.first)

        assert_empty env.clear.keys.grep(/\AAGENT_ORCHESTRATOR_/),
          "#{destination}/#{role.name} env.clear carries a name nothing reads."
        assert_empty env.secret_keys.grep(/\AAGENT_ORCHESTRATOR_/),
          "#{destination}/#{role.name} injects a live secret for no reader."
      end
    end
  end

  test "production bind-mounts the synced catalog and credentials into every role" do
    %w[web worker].each do |role|
      volumes = kamal_volumes("production", role)

      PRODUCTION_VOLUMES.each do |volume|
        assert_includes volumes, volume,
          "production/#{role} is missing #{volume}, so it resolves the in-image catalog " \
          "instead of the one artifacts-sync-prod delivers."
      end
    end
  end

  test "staging mounts nothing from /opt/zimmer" do
    %w[web worker].each do |role|
      assert_empty kamal_volumes("staging", role).grep(%r{\A/opt/zimmer}),
        "staging/#{role} has no artifacts-sync-prod delivery; it reads the in-image catalog."
    end
  end
end
