import { Controller } from "@hotwired/stimulus"
import { draftKey, saveDraft, loadDraft, clearDraft, pruneExpiredDraftsOnce } from "lib/draft_storage"

// How long to wait after the last keystroke before writing the draft. Long
// enough that a fast typist isn't writing to localStorage on every character,
// short enough that a reload a moment after typing still finds the text. Any
// pending write is flushed synchronously when the page is hidden, so the
// debounce never costs the user a draft.
const DRAFT_DEBOUNCE_MS = 300

// Character limits are read from data attributes passed from the server
// to ensure consistency with Session::PROMPT_MAX_LENGTH
export default class extends Controller {
  static targets = ["form", "textarea", "textareaMobile", "submitButton", "submitButtonMobile", "modeIndicator", "draftIndicator"]
  static values = {
    promptMaxLength: { type: Number, default: 500000 },
    sessionRunning: { type: Boolean, default: false },
    sessionId: Number,
    pendingSentMessage: { type: String, default: "" }
  }

  connect() {
    // Guard against connecting when required targets are missing.
    // This can happen during Turbo Stream replacements when elements with
    // data-turbo-permanent are being moved around in the DOM.
    // The controller will be reconnected once all targets are available.
    if (!this.hasTextareaTarget || !this.hasFormTarget || !this.hasSubmitButtonTarget) {
      return
    }

    // Track whether we just submitted the form - if so, don't restore preserved input
    this.justSubmitted = false
    this.submittedValue = null
    this.draftDebounceTimer = null
    this.initialized = true

    // Collect drafts for sessions this browser has stopped visiting.
    pruneExpiredDraftsOnce()

    // A stored draft is the user's own most recent text, so it outranks the
    // server's recovered `sent_message`: the recovered copy is what they sent
    // before the session stalled, and re-imposing it would discard whatever they
    // typed since — on exactly the sessions most likely to be reloaded.
    if (loadDraft(this.draftStorageKey)) {
      this.restorePreservedInput()
    } else if (this.pendingSentMessageValue && this.pendingSentMessageValue.trim() !== "") {
      this.preloadPendingSentMessage()
    } else {
      this.updateDraftIndicator()
    }

    // Auto-focus the textarea when the controller connects
    // Only focus if no other element is already focused (to avoid disrupting user)
    if (document.activeElement === document.body || !document.activeElement) {
      this.textareaTarget.focus()
    }

    // Initialize mode based on session status
    this.updateMode()

    // Listen for Turbo Stream replacements that target our form
    this.boundSaveInput = this.saveBeforeStreamRender.bind(this)
    document.addEventListener("turbo:before-stream-render", this.boundSaveInput)

    // Listen for successful form submissions to clear the textarea
    // We use BOTH form-level and document-level listeners for robustness:
    // - Form-level catches normal submissions
    // - Document-level catches cases where the form is replaced before the event fires
    this.boundHandleSubmitEnd = this.handleSubmitEnd.bind(this)
    this.formTarget.addEventListener("turbo:submit-end", this.boundHandleSubmitEnd)

    // Document-level listener as a fallback for when the form is replaced during submission
    this.boundHandleDocumentSubmitEnd = this.handleDocumentSubmitEnd.bind(this)
    document.addEventListener("turbo:submit-end", this.boundHandleDocumentSubmitEnd)

    // Write the draft down the moment the page is taken away. A backgrounded
    // PWA can be frozen — or discarded outright — before a debounce timer ever
    // fires, so `visibilitychange` and `pagehide` are the last reliable point
    // at which the text still exists anywhere. These are the events that make
    // the difference between "reopened the app and my prompt is there" and
    // losing the last few seconds of typing.
    this.boundFlushDraft = this.flushDraft.bind(this)
    document.addEventListener("visibilitychange", this.boundFlushDraft)
    window.addEventListener("pagehide", this.boundFlushDraft)
  }

  disconnect() {
    if (this.boundSaveInput) {
      document.removeEventListener("turbo:before-stream-render", this.boundSaveInput)
    }
    if (this.boundHandleSubmitEnd && this.hasFormTarget) {
      this.formTarget.removeEventListener("turbo:submit-end", this.boundHandleSubmitEnd)
    }
    if (this.boundHandleDocumentSubmitEnd) {
      document.removeEventListener("turbo:submit-end", this.boundHandleDocumentSubmitEnd)
    }
    if (this.boundFlushDraft) {
      document.removeEventListener("visibilitychange", this.boundFlushDraft)
      window.removeEventListener("pagehide", this.boundFlushDraft)
    }
    // A disconnect is itself a form of the page going away (a Turbo navigation
    // replacing the body). Don't leave the last keystrokes in a pending timer.
    //
    // Only when connect() actually ran: Stimulus reuses the instance, so after
    // an early return the flags below are whatever a previous connect left, and
    // flushing would persist a textarea this controller never adopted.
    if (this.initialized) this.flushDraft()
    this.initialized = false
  }

  // Save current input before a Turbo Stream replaces the form.
  // Only save if this stream is targeting the follow-up form itself
  saveBeforeStreamRender(event) {
    if (!this.sessionIdValue || !event.target) return

    // Check if the stream is targeting our form or textarea
    const streamElement = event.target
    const targetId = streamElement.getAttribute?.("target")

    // Only save if the stream is replacing our form container
    // This prevents saving when other streams (like enqueued messages list) are rendered
    const formContainerId = `session_${this.sessionIdValue}_follow_up_form`
    if (targetId !== formContainerId) return

    this.writeDraft()
  }

  // The key this session's composer draft lives under. Scoped by session id so
  // a draft written on one session never surfaces on another.
  get draftStorageKey() {
    return draftKey(`session:${this.sessionIdValue}`, "followUpPrompt")
  }

  // The composer renders a desktop and a mobile textarea and shows one of them.
  // They are kept mirrored on every keystroke, so either one can be read for the
  // draft regardless of which is currently on screen.
  //
  // Reading only the *visible* one would be a trap: `getActiveTextarea` falls
  // back to the desktop textarea whenever the mobile one is hidden, and on a
  // phone the desktop textarea is empty. Collapsing the drawer and backgrounding
  // the app would then persist "" over a real draft and delete it.
  currentDraftValue() {
    if (this.hasTextareaTarget) return this.textareaTarget.value
    if (this.hasTextareaMobileTarget) return this.textareaMobileTarget.value
    return ""
  }

  // Copy what was just typed into the other textarea, so neither is ever left
  // holding a value the other does not have.
  mirrorTextareas(source) {
    if (!source) return

    if (this.hasTextareaTarget && source !== this.textareaTarget) {
      this.textareaTarget.value = source.value
    }
    if (this.hasTextareaMobileTarget && source !== this.textareaMobileTarget) {
      this.textareaMobileTarget.value = source.value
    }
  }

  // Called on every keystroke via data-action. Writing on input is what makes a
  // draft survive a reload: a stream-render hook alone only fires when the
  // server happens to replace the form, which is not what a reopened PWA does.
  scheduleDraftSave(event) {
    // A restore synthesises an input event to wake the character counter; it is
    // not the user typing, and re-saving would refresh the draft's expiry.
    if (this.restoringDraft) return

    this.mirrorTextareas(event?.target)
    this.updateDraftIndicator()

    if (this.draftDebounceTimer) clearTimeout(this.draftDebounceTimer)
    this.draftDebounceTimer = setTimeout(() => {
      this.draftDebounceTimer = null
      this.writeDraft()
    }, DRAFT_DEBOUNCE_MS)
  }

  // Write any pending draft immediately. Safe to call with nothing pending.
  flushDraft(event) {
    // visibilitychange fires for both directions; only the hidden edge is the
    // "page is being taken away" signal worth acting on.
    if (event?.type === "visibilitychange" && document.visibilityState !== "hidden") return

    if (this.draftDebounceTimer) {
      clearTimeout(this.draftDebounceTimer)
      this.draftDebounceTimer = null
    }
    this.writeDraft()
  }

  writeDraft() {
    if (!this.sessionIdValue) return
    if (!this.hasTextareaTarget) return

    const value = this.currentDraftValue()

    // Don't re-persist the message currently being submitted — that would
    // resurrect it on the next load. Anything the user types *while* the submit
    // is in flight is a new draft and is still worth keeping.
    if (this.justSubmitted && value === this.submittedValue) return

    saveDraft(this.draftStorageKey, value)
    this.updateDraftIndicator()
  }

  // Show the draft in the collapsed mobile drawer's trigger bar. On a phone the
  // composer is behind that drawer, so restoring the text into a textarea the
  // user cannot see would look exactly like still having lost it.
  updateDraftIndicator() {
    if (!this.hasDraftIndicatorTarget) return

    const indicator = this.draftIndicatorTarget
    // On the submit path this runs before the textareas are cleared, so read the
    // intent rather than the DOM: the message is on its way out, not a draft.
    const draft = this.justSubmitted ? "" : this.currentDraftValue().trim()

    if (draft === "") {
      indicator.textContent = indicator.dataset.placeholder || ""
      indicator.classList.remove("italic")
      return
    }

    // Truncated here as well as by `truncate` in the markup: the CSS handles the
    // visual clip, this keeps the DOM from carrying a 500k-character prompt.
    indicator.textContent = `Draft: ${draft.length > 80 ? `${draft.slice(0, 80)}…` : draft}`
    indicator.classList.add("italic")
  }

  // Handle streams that explicitly clear the follow-up prompt textarea
  // This happens when a message is queued and the server sends turbo_stream.update("follow_up_prompt", "")
  // Handle form submission completion (form-level listener)
  // Clear the textarea after successful submission since data-turbo-permanent preserves it
  handleSubmitEnd(event) {
    // Only clear on successful submissions (2xx status codes)
    // The fetchResponse may not exist for non-fetch submissions
    if (event.detail?.success) {
      this.clearSubmittedTextareas()
      this.clearPreservedInput()
      // Reset the justSubmitted flag
      this.justSubmitted = false
      this.submittedValue = null
      // Whatever the user typed while the submit was in flight is now the draft.
      this.writeDraft()
    } else {
      // On error, re-enable the buttons and reset text
      if (this.hasSubmitButtonTarget) {
        this.submitButtonTarget.disabled = false
      }
      if (this.hasSubmitButtonMobileTarget) {
        this.submitButtonMobileTarget.disabled = false
      }
      this.updateMode() // This will reset the button text
      this.justSubmitted = false
      // The send failed, so the text is the user's again — put it back where
      // they can see it and make sure it is on disk.
      this.restoreAfterFailedSubmit()
    }
  }

  // A failed submit leaves the composer empty even though nothing was sent.
  // Refill it from the value that was submitted and re-persist it.
  restoreAfterFailedSubmit() {
    const submitted = this.submittedValue
    this.submittedValue = null
    if (!submitted || submitted.trim() === "") return

    if (this.hasTextareaTarget && this.textareaTarget.value === "") {
      this.textareaTarget.value = submitted
    }
    if (this.hasTextareaMobileTarget && this.textareaMobileTarget.value === "") {
      this.textareaMobileTarget.value = submitted
    }
    this.writeDraft()
  }

  // Handle form submission completion (document-level listener)
  // This is a fallback for when the form is replaced via Turbo Stream during submission,
  // which causes the form-level listener to be disconnected before the event fires.
  handleDocumentSubmitEnd(event) {
    // Only process if we were the ones who submitted
    if (!this.justSubmitted) return

    // Check if the submission was for our form (by checking the form's action URL)
    const form = event.target
    if (!form || form.tagName !== "FORM") return

    // Check if this form's action matches our expected endpoints
    const formAction = form.action || ""
    const sessionId = this.sessionIdValue
    if (!sessionId) return

    const isOurForm = formAction.includes(`/sessions/${sessionId}/enqueued_messages`) ||
                      formAction.includes(`/sessions/${sessionId}/follow_up`)
    if (!isOurForm) return

    // Only clear on successful submissions
    if (event.detail?.success) {
      // Find our textarea by ID (it has data-turbo-permanent so it persists)
      const textareaId = `session_${sessionId}_follow_up_textarea`
      const textarea = document.getElementById(textareaId)
      if (textarea && textarea.value === this.submittedValue) {
        textarea.value = ""
      }
      this.clearPreservedInput()
      this.justSubmitted = false
      this.submittedValue = null
      this.writeDraft()
    } else {
      // On error, reset state
      this.justSubmitted = false
      this.restoreAfterFailedSubmit()
    }
  }

  // Restore the persisted draft. Runs on connect, which covers both a Turbo
  // Stream replacing the form and a full page load after the PWA was reopened.
  restorePreservedInput() {
    if (!this.sessionIdValue) return

    const preserved = loadDraft(this.draftStorageKey)
    if (!preserved) {
      this.updateDraftIndicator()
      return
    }

    // Restore into BOTH textareas. The composer renders a desktop and a mobile
    // one and shows whichever fits the viewport, so filling only `textarea`
    // leaves a phone user looking at an empty box while their text is in storage.
    if (this.hasTextareaTarget && this.textareaTarget.value === "") {
      this.textareaTarget.value = preserved
    }
    if (this.hasTextareaMobileTarget && this.textareaMobileTarget.value === "") {
      this.textareaMobileTarget.value = preserved
    }

    // Let the character counter and any other input-driven UI catch up with the
    // text that just appeared. Guarded, because this event also reaches this
    // controller's own `scheduleDraftSave`, which would re-stamp `savedAt` and
    // give the draft a fresh 7 days on every page load — it would then never
    // expire for as long as the session is opened.
    this.restoringDraft = true
    try {
      // The caret sits at the end after a programmatic assignment. Send it to
      // the start first, or a draft like "/review" reads as a slash command in
      // progress and pops the typeahead unbidden on load.
      const active = this.getActiveTextarea()
      if (active) {
        active.selectionStart = 0
        active.selectionEnd = 0
        active.dispatchEvent(new Event("input", { bubbles: true }))
      }
    } finally {
      this.restoringDraft = false
    }

    this.updateDraftIndicator()

    // Don't clear it yet - we only clear after successful submission
  }

  // Preload pending sent message from server into the textarea
  // This is called when the session has a sent_message that was not confirmed
  // in the transcript before the session transitioned to paused/failed
  preloadPendingSentMessage() {
    const message = this.pendingSentMessageValue
    if (!message || message.trim() === "") return

    // A stored draft is newer than the server's recovered copy — it is what the
    // user has typed since. Leave it alone rather than overwriting it with the
    // message they sent before the session stalled.
    //
    // This runs before connect(): Stimulus starts its value observers first, so
    // the value callback below fires and would otherwise clear the draft before
    // connect() ever gets the chance to restore it.
    if (loadDraft(this.draftStorageKey)) {
      this.restorePreservedInput()
      return
    }

    // Only preload if textarea is currently empty (don't overwrite user's new input)
    if (this.hasTextareaTarget && this.textareaTarget.value === "") {
      this.textareaTarget.value = message
      // Trigger input event to update character counter
      this.textareaTarget.dispatchEvent(new Event("input", { bubbles: true }))
    }
    if (this.hasTextareaMobileTarget && this.textareaMobileTarget.value === "") {
      this.textareaMobileTarget.value = message
      this.textareaMobileTarget.dispatchEvent(new Event("input", { bubbles: true }))
    }

    // No draft was in play (checked above), so there is nothing to preserve —
    // seed the indicator from what was just filled in.
    this.updateDraftIndicator()
  }

  // Handle pendingSentMessage value changes (e.g., from Turbo Stream replacement)
  pendingSentMessageValueChanged() {
    // Only preload if we have a pending message and the session is not running
    if (this.pendingSentMessageValue && this.pendingSentMessageValue.trim() !== "" && !this.sessionRunningValue) {
      this.preloadPendingSentMessage()
    }
  }

  // Clear the preserved input (called after successful submission)
  clearPreservedInput() {
    if (!this.sessionIdValue) return
    // Cancel any in-flight debounced write, or it would land after this and
    // restore the draft we just cleared.
    if (this.draftDebounceTimer) {
      clearTimeout(this.draftDebounceTimer)
      this.draftDebounceTimer = null
    }
    clearDraft(this.draftStorageKey)
    this.updateDraftIndicator()
  }

  // Get the sessionStorage key for undo content
  getUndoStorageKey() {
    return `followUpPromptUndo_${this.sessionIdValue}`
  }

  // Save content to the undo buffer before clearing (persists across page navigation)
  saveToUndoBuffer(content) {
    if (!this.sessionIdValue || !content || content.trim() === "") return
    const key = this.getUndoStorageKey()
    sessionStorage.setItem(key, content)
  }

  // Get content from the undo buffer
  getUndoBuffer() {
    if (!this.sessionIdValue) return null
    const key = this.getUndoStorageKey()
    return sessionStorage.getItem(key)
  }

  // Clear the undo buffer (called after successful undo)
  clearUndoBuffer() {
    if (!this.sessionIdValue) return
    const key = this.getUndoStorageKey()
    sessionStorage.removeItem(key)
  }

  // Check if there's content available to undo
  hasUndoContent() {
    const content = this.getUndoBuffer()
    return content && content.trim() !== ""
  }

  // Restore the last submitted message from the undo buffer (triggered by Ctrl/Cmd+Z when textarea is empty)
  undoLastSubmission() {
    const content = this.getUndoBuffer()
    if (!content) return false

    const activeTextarea = this.getActiveTextarea()
    if (!activeTextarea) return false

    // Only undo if the textarea is empty (don't overwrite user's new input)
    if (activeTextarea.value.trim() !== "") {
      // Ask for confirmation if there's existing content
      if (!confirm("This will replace your current text with the previously submitted message. Continue?")) {
        return false
      }
    }

    // Restore the content to both textareas
    if (this.hasTextareaTarget) {
      this.textareaTarget.value = content
    }
    if (this.hasTextareaMobileTarget) {
      this.textareaMobileTarget.value = content
    }

    // Clear the undo buffer after restoring
    this.clearUndoBuffer()

    // Focus the textarea
    activeTextarea.focus()

    // Dispatch input event to update character counter
    activeTextarea.dispatchEvent(new Event("input", { bubbles: true }))

    return true
  }

  handleKeydown(event) {
    // Submit form on Cmd+Enter (Mac) or Ctrl+Enter (Windows/Linux)
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault()
      this.submitForm()
      return
    }

    // Handle Cmd+Z (Mac) or Ctrl+Z (Windows/Linux) for undo
    // Only intercept when textarea is empty - otherwise let browser handle native undo
    if (event.key === "z" && (event.metaKey || event.ctrlKey) && !event.shiftKey) {
      const activeTextarea = this.getActiveTextarea()
      if (activeTextarea && activeTextarea.value.trim() === "" && this.hasUndoContent()) {
        event.preventDefault()
        this.undoLastSubmission()
      }
    }
  }

  // Update the form mode based on session running status
  updateMode() {
    const isRunning = this.sessionRunningValue

    // Update form action based on mode
    if (isRunning) {
      // Change action to enqueue endpoint
      this.formTarget.action = `/sessions/${this.sessionIdValue}/enqueued_messages`
      this.submitButtonTarget.textContent = "Queue Message"

      // Show mode indicator if target exists
      if (this.hasModeIndicatorTarget) {
        this.modeIndicatorTarget.classList.remove("hidden")
      }
    } else {
      // Change action to follow_up endpoint
      this.formTarget.action = `/sessions/${this.sessionIdValue}/follow_up`
      this.submitButtonTarget.textContent = "Send Message"

      // Hide mode indicator if target exists
      if (this.hasModeIndicatorTarget) {
        this.modeIndicatorTarget.classList.add("hidden")
      }
    }
  }

  // Called when sessionRunning value changes
  sessionRunningValueChanged() {
    this.updateMode()
  }

  // Get the currently active textarea (mobile or desktop)
  getActiveTextarea() {
    // Check if we're on mobile by testing visibility
    if (this.hasTextareaMobileTarget && this.textareaMobileTarget.offsetParent !== null) {
      return this.textareaMobileTarget
    }
    if (this.hasTextareaTarget) {
      return this.textareaTarget
    }
    return null
  }

  // Get the currently active submit button (mobile or desktop)
  getActiveSubmitButton() {
    // Check if we're on mobile by testing visibility
    if (this.hasSubmitButtonMobileTarget && this.submitButtonMobileTarget.offsetParent !== null) {
      return this.submitButtonMobileTarget
    }
    if (this.hasSubmitButtonTarget) {
      return this.submitButtonTarget
    }
    return null
  }

  submitForm() {
    const activeButton = this.getActiveSubmitButton()
    const activeTextarea = this.getActiveTextarea()

    // Prevent double-submission (especially via keyboard shortcut while button is disabled)
    if (activeButton && activeButton.disabled) {
      return
    }

    if (!activeTextarea) {
      return
    }

    // Validate that textarea is not empty
    const promptText = this.sessionRunningValue ? "message" : "follow-up prompt"
    if (activeTextarea.value.trim() === "") {
      alert(`Please enter a ${promptText}`)
      return
    }

    // Validate prompt length
    if (activeTextarea.value.length > this.promptMaxLengthValue) {
      alert(`${promptText.charAt(0).toUpperCase() + promptText.slice(1)} is too long. Maximum ${this.promptMaxLengthValue.toLocaleString()} characters allowed.`)
      return
    }

    // Sync mobile textarea value to desktop textarea for form submission
    // The form uses the desktop textarea's name, so we need to copy the value
    if (this.hasTextareaMobileTarget && this.hasTextareaTarget && activeTextarea === this.textareaMobileTarget) {
      this.textareaTarget.value = this.textareaMobileTarget.value
    }

    // Disable all submit buttons to prevent double-submission
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = true
      this.submitButtonTarget.textContent = this.sessionRunningValue ? "Queueing..." : "Submitting..."
    }
    if (this.hasSubmitButtonMobileTarget) {
      this.submitButtonMobileTarget.disabled = true
      this.submitButtonMobileTarget.textContent = this.sessionRunningValue ? "Queueing..." : "Submitting..."
    }

    // Mark that we just submitted - this prevents saveBeforeStreamRender from
    // re-saving the input when the Turbo Stream response replaces the form
    this.justSubmitted = true
    this.submittedValue = activeTextarea.value

    // Save the submitted content to the undo buffer BEFORE clearing
    // This allows the user to recover their message with Ctrl+Z/Cmd+Z
    // even after navigating away from the page
    this.saveToUndoBuffer(activeTextarea.value)

    // The draft is deliberately NOT cleared here. Between requestSubmit() and
    // turbo:submit-end the message exists only in flight, and this is a phone —
    // if the OS discards the web view in that window, a draft already deleted is
    // gone for good (the undo buffer is sessionStorage, which a cold relaunch
    // also loses). handleSubmitEnd clears it once the server has confirmed.

    // Submit the form - requestSubmit() synchronously captures the form data
    // before the async network request begins
    this.formTarget.requestSubmit()

    // Clear all textareas IMMEDIATELY after requestSubmit()
    // This is safe because requestSubmit() has already captured the form data.
    // We clear it here rather than waiting for turbo:submit-end because:
    // 1. The form might be replaced via Turbo Stream before the event fires
    // 2. The event listener might be disconnected during the replacement
    // 3. This provides a more responsive UX (instant feedback)
    //
    // If the submission fails, the error handling in handleSubmitEnd will
    // re-enable the button, but the textarea stays cleared. User can now
    // use Ctrl+Z/Cmd+Z to restore their message from the undo buffer.
    this.clearSubmittedTextareas()
    this.updateDraftIndicator()
  }

  // Empty the composer after a submit, but only where it still holds the text
  // that was submitted. If the user has already started the next message, that
  // is theirs — clearing it would be the same data loss this controller exists
  // to prevent, just with a different trigger.
  clearSubmittedTextareas() {
    const submitted = this.submittedValue

    if (this.hasTextareaTarget && this.textareaTarget.value === submitted) {
      this.textareaTarget.value = ""
    }
    if (this.hasTextareaMobileTarget && this.textareaMobileTarget.value === submitted) {
      this.textareaMobileTarget.value = ""
    }
  }
}
