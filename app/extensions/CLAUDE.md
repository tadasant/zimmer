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
   drops the whole feature and the core falls back to native. That is the
   removability mechanism, and it lives here in the **source tree** — the built
   image carries this directory intact (see `.dockerignore` and
   `scripts/assert-extensions-shipped.sh`), so an extension merged to `main`
   runs in production once it is registered and toggled on.
3. **Zeitwerk collapses `app/extensions/*`** (see `config/application.rb`), so
   files here are **not** namespaced by their directory —
   `pty_transport/pty_claude_cli_adapter.rb` is `PtyClaudeCliAdapter`, not
   `PtyTransport::PtyClaudeCliAdapter`. Name classes as if they lived in
   `app/services/`.
4. **Enablement is schema-less** — the per-id `AppSetting#extension_states` JSONB
   map. Adding an extension needs **no migration** and no new column.
5. **"Extension", not "plugin."** "Plugin" is the AIR session concept
   (`PluginsConfig`); this layer is deliberately a different word.
6. **`image_canary/` is not an extension.** It holds no Ruby and registers
   nothing; it exists so the build can prove a subdirectory of this directory
   reached the image. Do not delete it and do not put a `.rb` file in it.
7. **Never create `pty_transport/` here.** `BUILTIN_EXTENSION_CLASSES` names
   `PtyTransportExtension`, and that class's code is withheld from this public
   repository on purpose — it depends on internal-only techniques we do not
   publish. Production mounts it read-only from a host directory at
   `/rails/app/extensions/pty_transport` (`config/deploy.production.yml`);
   here the name resolves to nothing and every seam stays native. Writing the
   extension, a PTY driver, or tests of either into this directory publishes
   the technique. `test/services/zimmer/extension_registry_test.rb` asserts
   that no built-in name resolves in this repo, so such a commit fails CI.

## Tests

Put an extension's tests under `test/extensions/<id>/` so they are deleted along
with the extension. The generic registry behavior is already covered by
`test/services/zimmer/extension_registry_test.rb` — don't re-test it per extension.
