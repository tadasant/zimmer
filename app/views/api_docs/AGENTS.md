# CLAUDE.md — API Docs View

You are modifying `show.html.erb`, the rendered HTML reference at `/api_docs`.

## ⚠️ Mirror every change to `docs/src/content/docs/extend/rest-api.md`

This view and **`docs/src/content/docs/extend/rest-api.md`** (published at https://docs.zimmer.tadasant.com/extend/rest-api/) are two parallel representations of the same content. They must describe the same endpoints, params, response fields, status codes, and terminology. If you edit one, edit the other in the same PR.

If your diff only modifies one of them, double-check that the other is already accurate — and call out in the PR description which surface was already correct.

## ⚠️ Match the implementation, not your memory

Before adding or editing content, verify against the actual code:

- Routes: `config/routes.rb` (look under `namespace :api { namespace :v1 ... }`)
- Param permit-lists: the relevant controller's `*_params` private method
- Response shapes: the controller's `*_json` builder methods (e.g. `session_json`, `log_json`)
- Validation rules and defaults: the model (e.g. `app/models/log.rb`'s `validates :level, inclusion: ...`)
- Lifecycle constants: `app/models/concerns/session_state_machine.rb` (e.g. `TRASH_RETENTION_PERIOD`)

See the parent `agents/agent-orchestrator/CLAUDE.md` ("Updating the REST API (and Its Docs)") for context and the drift history this guidance prevents.
