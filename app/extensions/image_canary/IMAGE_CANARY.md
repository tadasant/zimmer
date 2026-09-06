# `app/extensions/image_canary/` — not an extension

This directory holds no Ruby and registers nothing. It exists so that the build
can **prove** a subdirectory of `app/extensions/` reaches the published image.

Extensions ship in the image (see `.dockerignore`), and the only thing that can
take them back out is an exclusion pattern in `.dockerignore` — a one-line edit
with no other symptom. A deployed Zimmer would keep booting, `ExtensionRegistry`
would skip every class that no longer resolved, every seam would fall back to
native, and nothing would say so. That is exactly the failure
[#91](https://github.com/tadasant/zimmer/issues/91) was filed about, and it went
unnoticed long enough for the one extension that ever shipped to be rewritten as
an `AppSetting` column instead.

`scripts/assert-extensions-shipped.sh` looks for `IMAGE_CANARY.md` under
`app/extensions/*/` in the tree it is pointed at. A subdirectory is what
`/app/extensions/*/` used to exclude, so a canary at the *top* of
`app/extensions/` would prove nothing — `CLAUDE.md` sat there through the whole
outage. It has to be one level down.

Do not delete this directory, and do not add a `.rb` file to it. Zeitwerk
collapses `app/extensions/*` (see `config/application.rb`) and loads only `.rb`
files, so with none here the canary contributes nothing to the running app.
