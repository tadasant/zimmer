# frozen_string_literal: true

require "json"

# PiAirBridge — writes the AIR config that turns a Pi session's declared hooks and
# plugins into hooks and plugins Pi actually runs.
#
# == Why this file exists ==
#
# `air prepare pi` handles skills and stops there. `@pulsemcp/air-adapter-pi`'s own
# README is explicit: "Hooks — Pi has no AIR-translatable hook lifecycle. Hook
# entries are ignored; the manifest records `hooks: []`" and "Plugins — honored
# only as composition sugar: a plugin's declared *skills* are merged into the
# activation set; its MCP servers and hooks are ignored."
#
# So `air prepare pi --hook <id> --plugin <id>` runs, exits 0, and leaves nothing
# on disk that any part of Pi will read. Zimmer's two Pi extensions —
# `@tadasant/pi-hooks` and `@tadasant/pi-plugins` (see PiExtensions) — are what
# execute AIR hooks and AIR plugins inside Pi, and both are configured by an
# `air.json`-shaped file. This service writes those files.
#
# == What it writes, and why it is generated rather than pointed at the catalog ==
#
# Both extensions can discover a catalog on their own: `./air.json`, then
# `.air/air.json`, relative to Pi's working directory. Zimmer does not use that,
# for two reasons, and instead generates a closed mini-catalog under
# `<clone>/.pi/zimmer-air/` and names it explicitly through PI_HOOKS_AIR /
# PI_PLUGINS_CONFIG:
#
#   1. **Selection.** `@tadasant/pi-hooks` activates *every* hook in an index it
#      loads — it has no roots concept to filter on. Pointing it at Zimmer's own
#      `hooks/hooks.json` would run every hook in the catalog in every Pi session,
#      ignoring `session.catalog_hooks` entirely. The generated index IS the
#      selection, which is also why no `PI_PLUGINS` env var is needed: the
#      generated `plugins.json` carries `default_in_roots: ["*"]` on exactly the
#      plugins the session selected.
#   2. **The cloned repository gets a vote otherwise.** Discovery is relative to
#      the working directory, which is a clone of whatever repo the session works
#      on — and `tadasant/zimmer` itself has an `air.json` at its root. Cloning a
#      repository and starting Pi in it would be enough to adopt whatever hooks
#      that repo declares. Naming a Zimmer-owned path shadows discovery, so the
#      session runs the hooks Zimmer selected and no others.
#
# The files are written on every prepare, including when the session selects
# nothing, so the shadowing above holds for every Pi session rather than only the
# ones with hooks.
#
# == Two config files, not one ==
#
# `PI_HOOKS_AIR` and `PI_PLUGINS_CONFIG` point at different generated files
# because the two extensions have different jobs and must not both fire the same
# hook. `@tadasant/pi-plugins` translates a selected plugin's bundled hooks and
# dispatches them through its own runner; `@tadasant/pi-hooks` runs the hooks the
# session named directly. A hook reachable both ways would be spawned twice per
# event, so #direct_hooks subtracts anything a selected plugin already bundles.
#
# == MCP is deliberately not bridged ==
#
# `@tadasant/pi-plugins` can materialize a plugin's MCP servers into `.pi/mcp.json`
# for pi-mcp-adapter, and Zimmer must not let it. PiMcpConfigPostProcessor already
# writes every server the session is configured with — including plugin-bundled
# ones, via Session#user_selected_mcp_servers — into `<clone>/.mcp.json`, with
# secret resolution, Zimmer-instance retargeting, the elicitation address and npx
# cache pinning that the extension's plain `${VAR}` interpolation does not do.
# pi-mcp-adapter reads both files and merges them by name; the extension reserves
# names already claimed by `.mcp.json` and writes its own copy under the
# *qualified* name instead, which would start a second copy of every plugin server.
# So the generated plugins entries carry `mcp_servers: []` and the generated config
# declares no `mcp` index — one owner for MCP, and no "bundled server is not in any
# mcp index" warning for a server that is, in fact, already running.
#
# `skills: []` is there for the same reason: `air prepare pi` already merges a
# plugin's skills into the activation set and installs them into `.pi/skills/`, so
# contributing them again through the extension's `resources_discover` seam would
# offer Pi the same skill twice.
#
# == Degradation ==
#
# A selection the catalog no longer knows is dropped with a warning rather than
# raised on, mirroring AirPrepareService#scrubbed_catalog_skills: the catalog
# evolves independently of the sessions that reference it, and a removed hook id
# must cost one hook, not the session's whole startup.
class PiAirBridge < RuntimeArtifactBridge
  # Where the generated mini-catalog lives inside the clone. Under `.pi/` because
  # that is already Pi's own directory in the working tree (`.pi/skills/` is where
  # air-adapter-pi installs skills), and in a `zimmer-air/` subdirectory so it is
  # obvious on inspection that Zimmer wrote it rather than a human.
  CONFIG_DIR = File.join(".pi", "zimmer-air")

  # The file PI_HOOKS_AIR names, and the index it declares.
  HOOKS_AIR_FILENAME = "pi-hooks.air.json"
  HOOKS_INDEX_FILENAME = "hooks.json"

  # The file PI_PLUGINS_CONFIG names, and the two indexes it declares.
  PLUGINS_AIR_FILENAME = "pi-plugins.air.json"
  PLUGINS_INDEX_FILENAME = "plugins.json"
  PLUGIN_HOOKS_INDEX_FILENAME = "plugin-hooks.json"

  # The scope `@tadasant/pi-hooks` and `@tadasant/pi-plugins` qualify a generated
  # index's bare keys with. Both hard-code "local" for an index named directly by
  # an air.json (as opposed to one found by walking a `catalogs` entry), so the
  # references the generated plugins.json makes into the generated hooks index
  # have to be written with this prefix to resolve.
  GENERATED_SCOPE = "local"

  # Absolute path to the file PI_HOOKS_AIR should name for this working directory.
  # A module-level path helper rather than an instance method, because
  # PiRuntimeAdapter needs it at spawn time with only the working directory in hand.
  def self.hooks_air_path(working_directory)
    File.join(working_directory, CONFIG_DIR, HOOKS_AIR_FILENAME)
  end

  # Absolute path to the file PI_PLUGINS_CONFIG should name. See #hooks_air_path.
  def self.plugins_air_path(working_directory)
    File.join(working_directory, CONFIG_DIR, PLUGINS_AIR_FILENAME)
  end

  # The environment PiRuntimeAdapter must export so Pi's extensions read Zimmer's
  # generated config instead of discovering one in the cloned repository.
  #
  # Only variables whose file is actually on disk are returned: pointing
  # PI_HOOKS_AIR at a missing path makes `@tadasant/pi-hooks` log a warning, and
  # pointing PI_PLUGINS_CONFIG at one makes `@tadasant/pi-plugins` raise (which it
  # catches, but the session then falls back to discovery — the exact behavior the
  # variable exists to prevent). A session prepared before this bridge existed, or
  # one whose prepare failed, therefore gets Pi's own defaults rather than a
  # dangling override.
  #
  # @param working_directory [String]
  # @param file_system [FileSystemAdapter]
  # @return [Hash{String=>String}]
  def self.spawn_env(working_directory, file_system:)
    {
      "PI_HOOKS_AIR" => hooks_air_path(working_directory),
      "PI_PLUGINS_CONFIG" => plugins_air_path(working_directory)
    }.select { |_key, path| file_system.exists?(path) }
  end

  # Generate the mini-catalog. Idempotent: every file is rewritten from the
  # session's current selections, so a resume after the selections changed
  # converges rather than accumulating.
  def write!
    dir = File.join(working_directory, CONFIG_DIR)
    file_system.mkdir_p(dir)

    write_json(File.join(dir, HOOKS_INDEX_FILENAME), hook_index(direct_hooks))
    write_json(File.join(dir, HOOKS_AIR_FILENAME), {
      "name" => "zimmer-session-hooks",
      "hooks" => [ "./#{HOOKS_INDEX_FILENAME}" ]
    })

    # The plugin index is built FROM the hook index rather than beside it, so a
    # plugin can only reference a hook the index actually holds. Naming one it
    # dropped would put a dangling reference in a catalog Zimmer generated itself,
    # which the extension reports as "bundled hook … is not in any hooks index" —
    # the same class of warning the omitted `mcp` index exists to avoid.
    bundled = hook_index(plugin_hooks)
    write_json(File.join(dir, PLUGIN_HOOKS_INDEX_FILENAME), bundled)
    write_json(File.join(dir, PLUGINS_INDEX_FILENAME), plugin_index(bundled.keys.to_set))
    write_json(File.join(dir, PLUGINS_AIR_FILENAME), {
      "name" => "zimmer-session-plugins",
      "plugins" => [ "./#{PLUGINS_INDEX_FILENAME}" ],
      "hooks" => [ "./#{PLUGIN_HOOKS_INDEX_FILENAME}" ]
    })
  end

  private

  # The hooks `@tadasant/pi-hooks` runs: the ones the session named directly, less
  # anything a selected plugin already bundles (which `@tadasant/pi-plugins` runs
  # instead). Without the subtraction a hook selected both ways would be spawned
  # twice for every event it matches.
  def direct_hooks
    bundled = plugin_hooks.map { |id| short_id(id) }.to_set
    # Compared on the short id, which is the key both generated indexes are keyed
    # on. Comparing raw ids would let `git-push-ci-reminder` and
    # `@local/git-push-ci-reminder` name the same hook and miss each other, and
    # the cost of missing is the hook firing twice for every event it matches.
    Array(session.catalog_hooks).reject(&:blank?).reject { |id| bundled.include?(short_id(id)) }
  end

  # The hooks `@tadasant/pi-plugins` runs: every hook bundled by a plugin the
  # session selected.
  #
  # Session#plugin_derived_hooks is NOT what is wanted here — it excludes hooks
  # already in `catalog_hooks` so the UI renders each one once, which is exactly
  # the set that would then be dropped by both extensions.
  def plugin_hooks
    @plugin_hooks ||= selected_plugins.flat_map(&:hooks).uniq
  end

  # The catalog entries for the session's selected plugins, in selection order.
  # Session#selected_plugins does the same thing but is private, and this service
  # is not a Session collaborator so it resolves through PluginsConfig itself —
  # the same reader the UI and PiMcpConfigPostProcessor use.
  def selected_plugins
    @selected_plugins ||= Array(session.catalog_plugins).reject(&:blank?)
      .filter_map { |id| PluginsConfig.find(id) }
  end

  # An AIR hooks index: `{ "<short id>": { title, description, path } }`.
  #
  # Keyed on the short id because both extensions re-qualify a generated index's
  # keys as `@local/<key>`, and `path` is the catalog's absolute directory (AIR
  # absolutizes it during `air resolve`), so the hook body runs from where it
  # actually lives rather than from a copy.
  def hook_index(ids)
    ids.each_with_object({}) do |id, index|
      hook = HooksConfig.find(id)
      if hook.nil?
        warn_dropped("hook", id)
        next
      end
      if hook.absolute_path.blank?
        warn_dropped("hook", id, "the catalog entry has no path")
        next
      end

      key = short_id(id)
      if index.key?(key)
        warn_dropped("hook", id, "another hook already resolved to the short id #{key.inspect}")
        next
      end

      index[key] = {
        "title" => hook.title,
        "description" => hook.description.to_s,
        "path" => hook.absolute_path
      }
    end
  end

  # An AIR plugins index carrying each plugin's body INLINE rather than a `path`
  # to its `.plugin/plugin.json`.
  #
  # `@tadasant/pi-plugins` reads a manifest from disk only when the index entry has
  # a `path`; without one it uses the entry as the whole body. That is what lets
  # Zimmer state `skills: []` and `mcp_servers: []` for this runtime — see the
  # class docstring for why both belong to somebody else here — without editing or
  # copying the catalog's real manifests.
  #
  # `default_in_roots: ["*"]` is the selection: the extension activates plugins
  # whose `default_in_roots` includes `"*"`, and this index holds only the plugins
  # the session actually chose.
  #
  # @param resolvable_hooks [Set<String>] the short ids the generated plugin-hooks
  #   index actually holds; a bundled hook missing from it was already dropped and
  #   reported there, so referencing it here would only add a second complaint from
  #   the extension about a reference Zimmer knowingly could not satisfy.
  def plugin_index(resolvable_hooks)
    dropped = Array(session.catalog_plugins).reject(&:blank?) - selected_plugins.map(&:id)
    dropped.each { |id| warn_dropped("plugin", id) }

    selected_plugins.each_with_object({}) do |plugin, index|
      key = short_id(plugin.id)
      if index.key?(key)
        warn_dropped("plugin", plugin.id, "another plugin already resolved to that short id")
        next
      end

      index[key] = {
        "title" => plugin.title,
        "description" => plugin.description.to_s,
        "version" => plugin.version.to_s,
        # Rewritten to the ids the generated hooks index actually uses. The
        # catalog's ids carry their own scope (`@local/x`, or `@owner/repo/x` for a
        # remote catalog), while a generated index is re-qualified as `@local/<key>`
        # — so carrying the catalog's ids through verbatim would leave every
        # reference from a non-local catalog unresolvable.
        "hooks" => plugin.hooks.map { |hook_id| short_id(hook_id) }
          .select { |key| resolvable_hooks.include?(key) }
          .map { |key| "@#{GENERATED_SCOPE}/#{key}" },
        "skills" => [],
        "mcp_servers" => [],
        "default_in_roots" => [ "*" ]
      }
    end
  end

  # The unqualified tail of an AIR id.
  #
  # AirCatalogService resolves with `--no-scope`, so Zimmer's own ids are already
  # bare and this is the identity for every one of them today. It is here for the
  # references INSIDE a generated index, which the extensions re-qualify as
  # `@local/<key>` unconditionally: should a scoped id ever reach this service,
  # carrying it through verbatim would leave the reference unresolvable, while
  # `@local/git-push-ci-reminder` and `@owner/repo/git-push-ci-reminder` both
  # reduce to a key the generated index actually has.
  def short_id(id)
    id.to_s.split("/").last.to_s
  end

  def warn_dropped(kind, id, reason = "it is not in the resolved catalog")
    Rails.logger.warn(
      "[PiAirBridge] Dropping #{kind} #{id.inspect} for session #{session.id}: #{reason}"
    )
  end

  def write_json(path, data)
    file_system.write(path, "#{JSON.pretty_generate(data)}\n")
  end
end
