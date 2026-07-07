# Zimmer Extensions

An **Zimmer Extension** is a self-contained, individually-deletable bundle of optional
behavior that plugs into Zimmer's core seams without the core ever naming it. This
document explains why the seam exists, how it works, and the invariants that keep
it removable. For a step-by-step guide to writing one, see
[AUTHORING_AN_AO_EXTENSION.md](AUTHORING_AN_AO_EXTENSION.md).

## Why this exists

Zimmer is being extracted from the monorepo as standalone OSS. A few features depend
on internal-only techniques we do not want to publish — most notably the
**PTY transport**, which drives the interactive Claude Code TUI inside a
pseudo-terminal instead of calling `claude -p`. That technique leans on Claude
Code's TUI internals and is inherently fragile; it is not something to ship in an
open-source release.

The extension seam lets such a feature live entirely under
`app/extensions/<id>/` and be removed wholesale for the OSS build: **delete the
directory and everything still works**, falling back to the native path. The core
resolves extensions through `Ao::ExtensionRegistry` and never references a
concrete extension class, so a missing extension is not an error — its hooks
simply do not contribute.

## "Extension" vs AIR "plugin" — deliberately different words

This layer is intentionally **not** called a "plugin". In this codebase, "plugin"
already means an **AIR session plugin** (`PluginsConfig`) — a bundle of skills /
MCP servers / hooks injected INTO an agent session's workspace. An Zimmer Extension is
a different thing entirely: it alters how **Zimmer itself** drives a runtime — which
CLI adapter it spawns, which print-inference backend it uses, what env it hands
the child process. The word "plugin" is reserved for the AIR concept; this layer
is "extensions". Keep the vocabulary distinct in code, docs, and UI.

## The moving parts

| Piece | Location | Role |
|-------|----------|------|
| `Ao::Extension` | `app/services/ao/extension.rb` | Base class + hook contract. Defaults are all inert. |
| `Ao::ExtensionRegistry` | `app/services/ao/extension_registry.rb` | Registers built-ins and resolves extension-contributed behavior generically. |
| `config/initializers/ao_extensions.rb` | initializer | Registers built-ins in a `to_prepare` block (re-runs on dev reload). |
| `AppSetting#extension_states` | JSONB column | Per-id enablement map. Schema-less, so a new extension needs no migration. |
| `app/extensions/<id>/` | extension dirs | Each extension's class and any collaborators it owns. |

### Registration and the removability mechanism

Built-in extensions are listed by **class name** (string) in
`ExtensionRegistry::BUILTIN_EXTENSION_CLASSES` and resolved with
`safe_constantize`:

```ruby
BUILTIN_EXTENSION_CLASSES.each do |class_name|
  klass = class_name.safe_constantize
  next unless klass          # directory deleted → constant gone → skipped

  register(klass.new)
end
```

That `next unless klass` **is** the removability mechanism. Delete
`app/extensions/pty_transport/`, and `PtyTransportExtension` no longer resolves;
`register_builtins!` skips it; every seam that asked "does any enabled extension
override this?" now gets "no" and falls back to native. No core edit required.

Leaving the now-dead class name in `BUILTIN_EXTENSION_CLASSES` is harmless — it
just resolves to `nil` and is skipped — but tidying it up when you delete an
extension keeps the list honest.

### Zeitwerk `collapse` — why constants aren't namespaced by directory

`config/application.rb` collapses the per-extension directories:

```ruby
Rails.autoloaders.main.collapse(Rails.root.join("app/extensions/*"))
```

This means `app/extensions/pty_transport/pty_claude_cli_adapter.rb` autoloads as
`PtyClaudeCliAdapter` — **not** `PtyTransport::PtyClaudeCliAdapter`. The directory
is an organizational/deletability boundary, not a namespace. Moving the PTY files
from `app/services/` into `app/extensions/pty_transport/` therefore preserved
every constant name; no reference elsewhere in the app changed.

### Enablement store

`AppSetting#extension_states` is a JSONB map from string extension id to boolean.
There is **one** global lookup, `AppSetting.extension_enabled?(id, default:)`,
used by `Ao::Extension#enabled?`. Adding an extension needs no new column — only a
key in the map — which is the load-bearing property for a drop-in OSS extension.

The store replaced the two former per-feature boolean columns
(`pty_headless_inference`, `enable_tool_search`); the migration backfilled their
values into the `pty_transport` and `mcp_tool_search` keys.

## The hooks (core seams)

Every hook defaults to inert on the base class, so an extension only pays for the
seams it uses. The core consults the **registry**, never a concrete extension.

| Hook | Core seam that consults it | Fallback when no extension contributes |
|------|----------------------------|----------------------------------------|
| `cli_adapter_override(runtime)` | `RuntimeRegistry.cli_adapter_class_for` | the runtime bundle's default adapter |
| `provides_print_runner?` / `print_runner_backend(...)` | `ClaudePrintRunner.build` | `NativeClaudePrintRunner` (`claude -p`) |
| `spawn_env_contribution(context)` | `ClaudeSpawnEnv#build_claude_spawn_env` | Zimmer's baseline env (unchanged) |

Resolution for first-wins hooks (`cli_adapter_override`, print backend) follows
registration order in `BUILTIN_EXTENSION_CLASSES`. `spawn_env_contribution` merges
all enabled extensions' contributions (later wins on key collision).

## The two built-in extensions

- **`pty_transport`** (`PtyTransportExtension`) — the internal-only feature this
  seam was built to isolate. Bundles `PtyClaudeCliAdapter` (interactive agent
  sessions), `PtyClaudePrintRunner` (one-off inference), and
  `PtyClaudeRetryStrategy`. When enabled, replaces **every** `claude -p` call in
  Zimmer. This is the directory intended to be deleted for the OSS build.
- **`mcp_tool_search`** (`McpToolSearchExtension`) — flips `ENABLE_TOOL_SEARCH`
  to `true` for newly spawned Claude Code sessions via `spawn_env_contribution`.
  A small, self-contained example of the env-contribution seam.

Both are experimental and off by default, and both are surfaced in the settings
"Experimental" section, which is data-driven from `Ao::ExtensionRegistry.experimental`.

## Invariants (do not break these)

1. **The core never names a concrete extension.** Only `Ao::ExtensionRegistry`
   and `BUILTIN_EXTENSION_CLASSES` mention extension class names. Any `if
   SomeExtension` branch in core code defeats removability.
2. **Deleting `app/extensions/<id>/` must leave a working Zimmer.** Every seam falls
   back to native. If a deletion would break the build, the feature wasn't fully
   self-contained — pull the stragglers into the extension directory.
3. **Enablement is schema-less.** New extensions add a key to `extension_states`,
   never a column.
4. **"Extension", not "plugin"**, everywhere in this layer.

## Verifying removability

The registry test asserts that a missing built-in class is skipped rather than
raising (the `safe_constantize` path). To sanity-check by hand, temporarily
rename `app/extensions/pty_transport/` and boot a console: session creation for
`claude_code` should resolve `ClaudeCliAdapter` and
`ClaudePrintRunner.build` should return a `NativeClaudePrintRunner`.
