# Authoring a Zimmer Extension

A practical guide to adding a new **Zimmer Extension**. For the design rationale and
invariants, read [AO_EXTENSIONS.md](AO_EXTENSIONS.md) first.

An extension is worth reaching for when you have optional behavior that (a) alters
how Zimmer drives a runtime, and (b) you want to be able to enable/disable globally
and — critically — **delete wholesale** without touching core code. If neither of
those is true, you probably want a plain service, a config value, or a runtime
bundle role instead.

## Step 1 — Create the directory

Everything the extension owns lives under `app/extensions/<id>/`. Because
`config/application.rb` collapses `app/extensions/*`, files here are **not**
namespaced by the directory — `app/extensions/my_thing/my_widget.rb` autoloads as
`MyWidget`, not `MyThing::MyWidget`. Name your classes as if they lived in
`app/services/`.

```
app/extensions/my_thing/
  my_thing_extension.rb      # the Ao::Extension subclass
  my_widget.rb               # any collaborators the extension owns
```

Keep **everything** the feature needs in this directory (or in clearly-owned
siblings like a `lib/` driver script). The deletion test is: `rm -rf
app/extensions/my_thing/` and Zimmer still boots and works. If a collaborator has to
live elsewhere, make sure the core references it only through the extension.

## Step 2 — Subclass `Ao::Extension`

At minimum override `#id`. Override the hooks you need; the rest stay inert.

```ruby
# frozen_string_literal: true

class MyThingExtension < Ao::Extension
  def id = "my_thing"                 # stable, unique — the enablement key
  def title = "My thing"              # settings UI label
  def description = "One line for the settings toggle."

  # experimental? defaults to true  → shows under settings "Experimental"
  # default_enabled? defaults to false → off until an operator turns it on

  # Override only the hooks you use:
  def spawn_env_contribution(context = {})
    return {} unless context[:runtime].to_s == "claude_code"

    { "MY_ENV_VAR" => "1" }
  end
end
```

### The hooks

| Hook | Return | Consulted by |
|------|--------|--------------|
| `cli_adapter_override(runtime)` | a CLI adapter **class**, or `nil` | `RuntimeRegistry.cli_adapter_class_for` |
| `provides_print_runner?` | boolean | `ClaudePrintRunner.build` (cheap predicate) |
| `print_runner_backend(claude_binary:, model:, process_manager:, logger:)` | an instance responding to `#run(prompt:, timeout:)`, or `nil` | `ClaudePrintRunner.build` |
| `spawn_env_contribution(context)` | env `Hash` (merged over baseline), or `{}` | `ClaudeSpawnEnv#build_claude_spawn_env` |

`enabled?` is provided by the base class — it reads
`AppSetting.extension_enabled?(id, default: default_enabled?)`. You do not
implement it.

## Step 3 — Register the class

Add the class name (a string) to `BUILTIN_EXTENSION_CLASSES` in
`app/services/ao/extension_registry.rb`:

```ruby
BUILTIN_EXTENSION_CLASSES = %w[
  PtyTransportExtension
  McpToolSearchExtension
  MyThingExtension
].freeze
```

Order matters only for first-wins hooks (`cli_adapter_override`, print backend):
earlier entries win. It is resolved with `safe_constantize`, so if you later
delete the directory, leaving the name here is harmless (it resolves to `nil` and
is skipped) — though removing it keeps the list honest.

## Step 4 — Enablement is automatic

You do **not** add a migration or a column. Enablement is stored per-id in the
`AppSetting#extension_states` JSONB map. The settings "Experimental" section is
data-driven from `Ao::ExtensionRegistry.experimental`, so your extension's toggle
appears automatically with its `title` and `description`. The toggle submits
`app_setting[extensions][<id>]`, which `AppSettingsController#update` routes
through `AppSetting#set_extension_enabled` generically — no controller change
needed.

If your extension should be on by default (rare for an experiment), override
`default_enabled?` to return `true` and/or `experimental?` to return `false` (the
latter hides it from the Experimental section).

## Step 5 — Test it

Put the extension's tests under `test/extensions/<id>/` so they are deleted along
with the extension. Cover:

- Each hook you overrode, for both the "applies" and "does not apply" cases.
- Integration through the seam if the extension changes core behavior (e.g. that
  `RuntimeRegistry.cli_adapter_class_for("claude_code")` returns your adapter when
  the extension is enabled).

`test/services/ao/extension_registry_test.rb` already covers the generic registry
behavior (registration, enabled filtering, hook resolution order, the
`safe_constantize` skip). You do not need to re-test that.

## Checklist

- [ ] `app/extensions/<id>/<id>_extension.rb` subclasses `Ao::Extension`, overrides `#id`.
- [ ] All collaborators live under `app/extensions/<id>/` (or a clearly-owned sibling).
- [ ] Class name added to `BUILTIN_EXTENSION_CLASSES`.
- [ ] No core file names the extension class (only the registry does).
- [ ] `rm -rf app/extensions/<id>/` leaves Zimmer booting and working (native fallback).
- [ ] Tests under `test/extensions/<id>/`.
