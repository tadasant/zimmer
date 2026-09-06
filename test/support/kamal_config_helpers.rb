# frozen_string_literal: true

# Renders the MERGED Kamal config for a deploy destination, offline.
#
# `config/deploy.yml` holds what both destinations share; `config/deploy.<dest>.yml`
# holds only what differs. Reading a destination file on its own therefore describes
# only half of what its containers get -- and the half it omits (the durable volumes,
# `init: true`, the worker's `cmd`) is exactly the half whose loss is silent. So every
# assertion about a deployed container reads the merged result instead.
#
# The merge is Kamal's own: `Kamal::Configuration.load_config_files` folds the
# destination file over the base with ActiveSupport's `deep_merge!`, which recurses
# into hashes and REPLACES arrays. Rendering it here rather than reimplementing it
# means these tests track the installed Kamal rather than an assumption about it.
#
# Test files that use this must `require "kamal"` themselves -- a require in a support
# file is loaded for every run in the whole suite, and hides its own absence elsewhere.
module KamalConfigHelpers
  # Discovered rather than listed, so a new destination is covered the moment its file
  # exists. `config/deploy.yml` is the shared base and has no `.<dest>.` segment, so the
  # glob excludes it by construction.
  DEPLOY_DESTINATIONS = Rails.root.glob("config/deploy.*.yml").filter_map do |path|
    path.basename.to_s[/\Adeploy\.(.+)\.yml\z/, 1]
  end.sort.freeze

  # The deploy shell supplies hosts and the nested-Docker switch. Pin the hosts (a role
  # with no host has no `docker run` to inspect) so a render never depends on what the
  # machine running the suite happens to export.
  KAMAL_RENDER_ENV = {
    "PRODUCTION_HOST" => "198.51.100.10",
    "STAGING_HOST" => "198.51.100.11",
    "PRODUCTION_DB_HOST" => "managed-db.example.internal"
  }.freeze

  # `nested_docker` is passed through to ZIMMER_NESTED_DOCKER; nil leaves it unset, so
  # each destination's own default applies.
  def kamal_config(destination, nested_docker: nil)
    with_kamal_render_env("ZIMMER_NESTED_DOCKER" => nested_docker) do
      Kamal::Configuration.create_from(
        config_file: Rails.root.join("config/deploy.yml"),
        destination: destination,
        version: "test"
      )
    end
  end

  # The merged config as a plain hash, shaped like the YAML the two files describe
  # together -- `dig("servers", "worker", "options", "runtime")` and friends.
  def kamal_raw_config(destination, nested_docker: nil)
    kamal_config(destination, nested_docker: nested_docker).raw_config.to_h.deep_stringify_keys
  end

  # The `docker run` Kamal would issue for a role, as one string. This is the last word
  # on what a container gets: it folds in the role's own options AND the top-level
  # `volumes:` key, which never appears under `servers`.
  def kamal_docker_run(destination, role_name, nested_docker: nil)
    config = kamal_config(destination, nested_docker: nested_docker)
    role = config.role(role_name)

    Kamal::Commands::App
      .new(config, role: role, host: role.hosts.first)
      .run(hostname: "test")
      .flatten.map(&:to_s).join(" ")
  end

  # Every `--volume` argument on a role's `docker run`, as `source:container_path[:opts]`
  # strings with Kamal's quoting stripped. Role options quote their values and the
  # top-level `volumes:` key does not; the shell erases that difference, so this does too.
  def kamal_volumes(destination, role_name, nested_docker: nil)
    run = kamal_docker_run(destination, role_name, nested_docker: nested_docker)

    run.scan(/--volume (?:"([^"]+)"|(\S+))/).map { |quoted, bare| quoted || bare }
  end

  private

  def with_kamal_render_env(overrides = {})
    values = KAMAL_RENDER_ENV.merge(overrides)
    keys = values.keys | [ "KAMAL_DESTINATION" ]
    previous = ENV.to_h.slice(*keys)

    keys.each { |key| ENV.delete(key) }
    values.each { |key, value| ENV[key] = value unless value.nil? }
    yield
  ensure
    keys.each { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end
end
