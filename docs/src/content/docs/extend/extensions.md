---
title: Extensions
description: The Zimmer::Extension seam — what an extension can override, what ships today, and how to write and install one.
sidebar:
  order: 3
---

An **extension** is a self-contained, individually-deletable bundle of optional behavior that alters
how *Zimmer itself* drives a runtime. Core code never names a concrete extension.

:::note[Not to be confused with AIR plugins]
The word "plugin" is reserved for [AIR session plugins](/air/artifacts/#plugins) — bundles of skills
and MCP servers injected into the agent's clone. An **extension** is a Ruby object that changes
Zimmer's own behavior. Different layer entirely.
:::

## The contract

`Zimmer::Extension` (`app/services/zimmer/extension.rb`), `API_VERSION = 1`.

**Identity:**

```ruby
id                 # required — raises NotImplementedError. This is the enablement key.
title              # default: id.humanize
description        # default: ""
experimental?      # default: true
default_enabled?   # default: false
enabled?           # provided — reads AppSetting.extension_enabled?(id, default: default_enabled?)
```

**Hooks** (all inert by default — override only what you need):

```ruby
cli_adapter_override(runtime)        # → an adapter class, or nil
provides_print_runner?               # → Boolean
print_runner_backend(claude_binary:, model:, process_manager:, logger:)
                                     # → an object responding to #run(prompt:, timeout:)
spawn_env_contribution(context = {}) # → Hash. context is { runtime: "claude_code" }
```

## The three mount points

Exactly three places in core consult the registry:

```mermaid
flowchart LR
    E["Zimmer::ExtensionRegistry"]
    E -->|"cli_adapter_override_for(runtime)"| R["RuntimeRegistry.cli_adapter_class_for<br/>(first enabled wins, registration order)"]
    E -->|"print_runner_backend(...)"| P["ClaudePrintRunner.build<br/>(fallback: NativeClaudePrintRunner)"]
    E -->|"spawn_env_contributions(runtime:)"| S["ClaudeSpawnEnv#build_claude_spawn_env<br/>(merged, later wins)"]
```

:::caution[Only one of those three is runtime-generic]
`spawn_env_contribution` receives a `runtime` context, which implies it applies to any runtime. It
doesn't: `ClaudeSpawnEnv` is the only caller, so neither `CodexRuntimeAdapter#spawn_process` nor
`PiRuntimeAdapter#spawn_process` reaches the registry. Extension env contributions are unreachable
for Codex and [Pi](/sessions/runtimes/) sessions alike.

The other two mount points are Claude-specific by name (`ClaudePrintRunner`, `ClaudeSpawnEnv`).
:::

## What ships: the seam, and no extensions

`BUILTIN_EXTENSION_CLASSES` is empty. The seam is live — the registry, the base class, the three
mount points, and the Settings → Experimental rendering all work — but no extension is registered.

The one that used to ship was `McpToolSearchExtension` (id `mcp_tool_search`), whose only hook
returned `{"ENABLE_TOOL_SEARCH" => "true"}` for Claude Code. It is gone, because at the time it could
never do its job: `.dockerignore` then excluded `/app/extensions/*/`, so the class did not exist in
any built image, the registry skipped it, and the `ENABLE_TOOL_SEARCH=false` baseline always stood in
production. MCP tool search is now a first-class `AppSetting` column, on by default — see
[Spawning a session](/sessions/spawning/#mcp-tool-search). The `mcp_tool_search` key
is dropped from `extension_states` by the same migration, so there is only ever one control.

That exclusion is gone ([#91](https://github.com/tadasant/zimmer/issues/91)). An extension
directory added to `app/extensions/` now reaches every built image, and the build fails if it does
not — see [Extensions do ship in the image](/operate/deploying/#extensions-do-ship-in-the-image).
So the choice between an extension and an `AppSetting` column is back to being about what the thing
*is*: an extension changes how Zimmer drives a runtime, a column is a value the app reads.

:::danger[The old docs described a second extension that does not exist]
`docs/AO_EXTENSIONS.md` described "the two built-in extensions" and documented `pty_transport` /
`PtyTransportExtension` (bundling `PtyClaudeCliAdapter`, `PtyClaudePrintRunner`,
`PtyClaudeRetryStrategy`) as shipping.

No such directory or class exists in this repo. `pty_transport` survives only in code comments and in
the (now deleted) docs. The old doc's "Verifying removability" section told you to rename
`app/extensions/pty_transport/` — a directory that isn't there.
:::

## Enable, install, remove

**Enable** — Settings → Experimental, which writes to `AppSetting#extension_states` (a JSONB map of
`id → bool`). No migration per extension. Or from a console:

```ruby
AppSetting.first_or_create!.tap { |s| s.set_extension_enabled("my_thing", true) }.save!
```

With no extension registered, that section of the page renders only the first-class experimental
settings.

**Install** — there is nothing to install. `Dockerfile` blanket-copies the repository into `/rails`
and nothing in `.dockerignore` takes `app/extensions/` back out, so an extension merged to `main` is
in the next image and in every container that image starts. The only operating step is the toggle
above.

There used to be a `scripts/install-extension.sh`, which `docker cp`'d a directory into a running
container and restarted it. It is deleted. It needed a shell on the production host — which
[the invariants](/operate/deploying/#ops-actions-ship-with-the-deploy) say is a defect to design out,
not a procedure to document — and whatever it installed was gone at the next deploy.

**Remove** — `rm -rf app/extensions/<id>/`. `ExtensionRegistry` resolves builtins with
`safe_constantize` and skips anything that returns `nil`, so every seam falls back to native behavior.
Leaving the dead name in `BUILTIN_EXTENSION_CLASSES` is harmless. *That* is the removability
mechanism, and it's a good one.

:::note[Removability is a property of the source tree, not of the image]
The two got conflated once, and it cost the seam its only extension. Deleting the directory from the
repository is what drops a feature; the `safe_constantize` skip is what makes that safe with no core
edit. Stripping the directory at *image-build* time is a different thing wearing the same clothes —
it does not demonstrate removability, it just guarantees that the one build meant to carry an
internal-only feature never does.
:::

:::caution[`app/extensions/image_canary/` is not an extension]
It holds no Ruby and registers nothing. `scripts/assert-extensions-shipped.sh` looks for the marker
file inside it to prove a *subdirectory* of `app/extensions/` survived into the image — the old rule
excluded subdirectories while leaving `app/extensions/CLAUDE.md` in place, so a marker at the top of
the tree would have passed throughout the outage. Don't delete it, and don't put a `.rb` file in it.
:::

## Writing one

```ruby
# app/extensions/my_thing/my_thing_extension.rb
class MyThingExtension < Zimmer::Extension
  def id = "my_thing"
  def title = "My Thing"
  def description = "Does the thing."
  def default_enabled? = false

  def spawn_env_contribution(context = {})
    return {} unless context[:runtime] == "claude_code"
    { "MY_FLAG" => "1" }
  end
end
```

Then add `"MyThingExtension"` to `Zimmer::ExtensionRegistry::BUILTIN_EXTENSION_CLASSES`.

:::note[The autoloader collapses the directory]
`config/application.rb` does
`Rails.autoloaders.main.collapse(Rails.root.join("app/extensions/*"))`.

So `app/extensions/my_thing/my_widget.rb` must define `MyWidget`, not `MyThing::MyWidget`.
:::

Register it in `config/initializers/zimmer_extensions.rb`? No — that file only calls `reset!` and
`register_builtins!` inside a `to_prepare` block (so it survives dev reloads). Adding the class name
to `BUILTIN_EXTENSION_CLASSES` is the whole registration.

Tests go in `test/extensions/<id>/`. The generic registry test lives at
`test/services/zimmer/extension_registry_test.rb`.
