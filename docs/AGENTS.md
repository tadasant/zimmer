# CLAUDE.md — `docs/`

Most files here are standalone references — edit them with normal scope discipline.

## ⚠️ Special case: `REST_API.md`

`REST_API.md` is **paired** with `app/views/api_docs/show.html.erb`, the rendered HTML reference at `/api_docs`. The two must stay in sync.

If you edit `REST_API.md`:

- Make the equivalent edit to `app/views/api_docs/show.html.erb` in the same PR
- If your edit is correcting drift, verify the HTML view doesn't have the same bug
- Verify endpoints, params, response fields, and terminology against the actual code (routes, controller permit-lists, `*_json` builders, model validations, lifecycle constants) — do not edit from memory

See the parent `agents/agent-orchestrator/CLAUDE.md` ("Updating the REST API (and Its Docs)") for the rationale and the drift history this guidance prevents.
