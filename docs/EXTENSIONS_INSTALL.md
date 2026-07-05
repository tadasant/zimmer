# Installing extensions

Zimmer's core image ships **without** any extension (see `.dockerignore`, which
excludes `app/extensions/*/`). The extension registry resolves built-in extension
classes with `safe_constantize`, so a missing `app/extensions/<id>/` directory
simply resolves to `nil` and is skipped — the core falls back to native behavior.
"Installing" an extension means placing its directory back so its class resolves.

See [AO_EXTENSIONS.md](AO_EXTENSIONS.md) for the design and
[AUTHORING_AN_AO_EXTENSION.md](AUTHORING_AN_AO_EXTENSION.md) for writing one.

## Install into a running container

```bash
scripts/install-extension.sh --list                       # show available extensions
scripts/install-extension.sh mcp_tool_search --container zimmer
```

This `docker cp`s `app/extensions/mcp_tool_search/` into the container and
restarts it. Then enable it:

- **UI:** Settings → Experimental → toggle the extension, or
- **Console:** `s = AppSetting.first_or_create!; s.set_extension_enabled("mcp_tool_search", true); s.save!`

## Install into a checkout (rebuild)

```bash
scripts/install-extension.sh mcp_tool_search --path /srv/zimmer
```

Copies the extension into a checkout so your next image build includes it.

## Why extensions are not in the core image

Keeping optional behavior out of core keeps the published image minimal and lets
internally-developed extensions live in a private overlay (e.g. `tadasant-internal`)
without being part of the public release. Removability is a hard invariant:
deleting an extension directory must always leave a working app.
