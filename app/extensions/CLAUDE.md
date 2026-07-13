# CLAUDE.md — `app/extensions/`

Everything here is an **Zimmer Extension**: a self-contained, individually-deletable
bundle of optional behavior resolved through `Zimmer::ExtensionRegistry`. Read
**[Extensions](https://docs.zimmer.tadasant.com/extend/extensions/)** — the contract, the invariants, and how to
write one — before adding or changing anything in this directory.

## The invariants that make this directory work

1. **The core never names a concrete extension.** Only
   `app/services/zimmer/extension_registry.rb` (via `BUILTIN_EXTENSION_CLASSES`)
   mentions extension class names. If you find yourself writing `if
   SomeExtension` in core code, stop — that defeats removability.
2. **Deleting `app/extensions/<id>/` must leave a working Zimmer.** Keep every
   collaborator a feature needs inside its own `<id>/` directory (or a clearly
   owned sibling like a `lib/` driver script), so `rm -rf app/extensions/<id>/`
   drops the whole feature and the core falls back to native.
3. **Zeitwerk collapses `app/extensions/*`** (see `config/application.rb`), so
   files here are **not** namespaced by their directory —
   `pty_transport/pty_claude_cli_adapter.rb` is `PtyClaudeCliAdapter`, not
   `PtyTransport::PtyClaudeCliAdapter`. Name classes as if they lived in
   `app/services/`.
4. **Enablement is schema-less** — the per-id `AppSetting#extension_states` JSONB
   map. Adding an extension needs **no migration** and no new column.
5. **"Extension", not "plugin."** "Plugin" is the AIR session concept
   (`PluginsConfig`); this layer is deliberately a different word.

## Tests

Put an extension's tests under `test/extensions/<id>/` so they are deleted along
with the extension. The generic registry behavior is already covered by
`test/services/zimmer/extension_registry_test.rb` — don't re-test it per extension.
