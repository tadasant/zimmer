# PR #300 verification media

Screenshots and a screen recording captured on staging (https://staging.zimmer.tadasant.com)
running `ghcr.io/tadasant/zimmer:staging-3de7012`, for PR #300.

This branch exists only to host binaries the PR description embeds. The session's
remote-filesystem MCP server (the normal upload path) returned
`invalid_grant: Invalid JWT Signature` on every call, so the media lives here
instead of in an object store. Nothing here is part of the change.
