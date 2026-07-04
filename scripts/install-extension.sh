#!/usr/bin/env bash
# Install a Zimmer extension into a running core container (or a local checkout).
#
# The core image ships WITHOUT any app/extensions/<id>/ directory (see
# .dockerignore). The extension registry resolves built-in extension classes
# with `safe_constantize`, so a missing directory resolves to nil and is skipped
# — the core simply falls back to native behavior. "Installing" an extension
# means placing its directory back so its class resolves again.
#
# Usage:
#   scripts/install-extension.sh <extension-id> --container <name-or-id>
#   scripts/install-extension.sh <extension-id> --path <checkout-dir>
#   scripts/install-extension.sh --list
#
# Examples:
#   scripts/install-extension.sh mcp_tool_search --container zimmer
#   scripts/install-extension.sh mcp_tool_search --path /srv/zimmer
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_SRC_ROOT="$REPO_ROOT/app/extensions"

list_available() {
  echo "Available extensions in this repo:"
  find "$EXT_SRC_ROOT" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | sed 's/^/  - /'
}

if [[ "${1:-}" == "--list" || $# -eq 0 ]]; then
  list_available
  exit 0
fi

EXT_ID="$1"; shift
MODE=""; TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) MODE="container"; TARGET="$2"; shift 2 ;;
    --path)      MODE="path";      TARGET="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

SRC="$EXT_SRC_ROOT/$EXT_ID"
if [[ ! -d "$SRC" ]]; then
  echo "Extension '$EXT_ID' not found under app/extensions/." >&2
  list_available
  exit 1
fi

case "$MODE" in
  container)
    echo "Copying extension '$EXT_ID' into container '$TARGET'..."
    docker cp "$SRC" "$TARGET:/rails/app/extensions/$EXT_ID"
    echo "Restarting container to pick up the extension..."
    docker restart "$TARGET" >/dev/null
    echo "Done. Container restarted."
    ;;
  path)
    echo "Copying extension '$EXT_ID' into checkout '$TARGET'..."
    mkdir -p "$TARGET/app/extensions"
    cp -R "$SRC" "$TARGET/app/extensions/$EXT_ID"
    echo "Done. Rebuild/restart the app to pick it up."
    ;;
  *)
    echo "Specify --container <name> or --path <dir>." >&2
    exit 2
    ;;
esac

cat <<EOF

Next steps:
  1. The extension class is registered but OFF by default. Enable it in the app:
     Settings -> Experimental -> toggle "$EXT_ID"
     (or in a rails console:
        s = AppSetting.first_or_create!; s.set_extension_enabled("$EXT_ID", true); s.save!)
  2. Newly spawned agent sessions will use the extension once enabled.
EOF
