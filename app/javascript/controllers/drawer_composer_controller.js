import { Controller } from "@hotwired/stimulus"
import { followUpDraftKey, saveDraft, loadDraft } from "lib/draft_storage"

// The provisional composer in the session drawer's loading skeleton
// (_drawer_composer.html.erb): a textarea a reader can type into while the
// detail body is still in flight.
//
// It writes to the same draft the real composer restores from, on every
// keystroke, so nothing typed here depends on the hand-off succeeding; it starts
// out holding that draft, so what was typed on an earlier visit is here too.
// The caret and focus travel separately — see lib/composer_handoff.js and
// session-drawer#handleBeforeFrameRender.
//
// Sending waits for the real composer: the button here is disabled, and
// Cmd/Ctrl+Enter does nothing, because which endpoint a message goes to
// (send now or queue behind a running turn) is the server-rendered form's call.
export default class extends Controller {
  static targets = ["textarea"]
  static values = { sessionId: Number }

  connect() {
    if (!this.sessionIdValue) return
    const draft = loadDraft(this.draftStorageKey)
    if (draft && this.textareaTarget.value === "") this.textareaTarget.value = draft
  }

  save() {
    if (!this.sessionIdValue) return
    saveDraft(this.draftStorageKey, this.textareaTarget.value)
  }

  get draftStorageKey() {
    return followUpDraftKey(this.sessionIdValue)
  }
}
