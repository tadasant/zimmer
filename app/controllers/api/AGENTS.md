# CLAUDE.md — API Controllers

You are modifying code under `app/controllers/api/`. This is the **REST API surface** that external consumers use.

This file's guidance applies to every controller in this directory subtree — `v1/*`, `base_controller.rb`, and `secrets_controller.rb` all shape the API surface in different ways.

## ⚠️ Keep the docs in sync

The REST API has **two documentation surfaces that must stay in sync** with this code:

1. **`docs/src/content/docs/extend/rest-api.md`** — the canonical reference, published at https://docs.zimmer.tadasant.com/extend/rest-api/
2. **`app/views/api_docs/show.html.erb`** — rendered HTML page at `/api_docs`

If your change does any of the following, update **both** doc surfaces in the same PR:

- Add, remove, or rename an endpoint
- Add, remove, or rename a request parameter (incl. permit-list changes)
- Change a response field — name, type, presence, semantics
- Change a status code or error shape
- Change validation rules visible at the boundary (e.g. a param going from optional → required)
- Rename a concept (e.g. `archived` ↔ `trash`, `git_root` ↔ `agent_root`) — update the Terminology section too

After your code change, grep both doc files for the affected endpoint path, the changed param name, and any renamed concept. Reconcile any mismatches.

See the repo-root `AGENTS.md` for the wider convention, and `docs/src/content/docs/extend/rest-api.md` for the API reference itself.

## Public-contract reminder

These endpoints are **public-facing**. Per the repo-wide backwards-compatibility policy, breaking changes (renamed fields, removed endpoints, changed status codes) require an explicit call-out to the user in your PR description. Prefer additive changes when feasible.
