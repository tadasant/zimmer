import { Controller } from "@hotwired/stimulus"

// Handles trigger form interactivity including:
// - Adding/removing trigger conditions
// - Condition type switching (Slack, Schedule, Zimmer Event) per condition card
// - Schedule mode switching (Recurring/One-time) per condition card
// - Schedule unit-dependent field visibility (day of week, time, timezone)
export default class extends Controller {
  static targets = [
    "conditionsContainer", "conditionCard", "conditionTypeSelect",
    "slackConfig", "scheduleConfig", "aoEventConfig",
    "channelSelect", "channelStatus", "channelId", "channelName",
    "channelManual", "channelManualInput",
    "unitSelect", "dayOfWeekContainer", "timeContainer", "timezoneContainer",
    "scheduleModeRadio", "recurringFields", "oneTimeFields", "scheduledAtInput",
    "destroyField", "conditionNumber",
    "promptHelp",
    "reuseSubOptions"
  ]
  static values = {
    slackConfigured: Boolean,
    channelsUrl: { type: String, default: "/triggers/channels" },
    conditions: Array,
    conditionIndex: { type: Number, default: 0 }
  }

  connect() {
    // Track the highest condition index for generating new condition fields
    this.conditionIndexValue = this.conditionCardTargets.length

    // Initialize schedule field visibility for each existing condition
    this.conditionCardTargets.forEach(card => {
      const unitSelect = card.querySelector("[data-trigger-form-target='unitSelect']")
      if (unitSelect) {
        this.updateScheduleFieldsInCard(card, unitSelect.value)
      }

      // Initialize schedule mode visibility (recurring vs one-time)
      const checkedRadio = card.querySelector("[data-trigger-form-target='scheduleModeRadio']:checked")
      if (checkedRadio) {
        this.updateScheduleModeInCard(card, checkedRadio.value)
      }

      // Lazily load the channel dropdown for any card whose Slack config is already visible
      this.maybeLoadChannels(card)
    })
  }

  // Show/hide reuse sub-options when the reuse_session checkbox is toggled
  toggleReuseSubOptions(event) {
    if (this.hasReuseSubOptionsTarget) {
      this.reuseSubOptionsTarget.classList.toggle("hidden", !event.target.checked)
    }
  }

  // Handle condition type change within a condition card
  handleConditionTypeChange(event) {
    const card = event.target.closest("[data-trigger-form-target='conditionCard']")
    if (!card) return

    const type = event.target.value

    const slackConfig = card.querySelector("[data-trigger-form-target='slackConfig']")
    const scheduleConfig = card.querySelector("[data-trigger-form-target='scheduleConfig']")
    const aoEventConfig = card.querySelector("[data-trigger-form-target='aoEventConfig']")

    if (slackConfig) slackConfig.classList.toggle("hidden", type !== "slack")
    if (scheduleConfig) scheduleConfig.classList.toggle("hidden", type !== "schedule")
    if (aoEventConfig) aoEventConfig.classList.toggle("hidden", type !== "ao_event")

    // Lazily load the channel list the first time this card's Slack config is shown
    if (type === "slack") this.loadChannelsForCard(card)
  }

  // ── Slack channel dropdown ──────────────────────────────────────────────
  // The channel list is fetched lazily (only when a Slack condition is shown)
  // and shared across every condition card via a single cached promise.

  // Load channels for a card only if its Slack config is currently visible.
  maybeLoadChannels(card) {
    const slackConfig = card.querySelector("[data-trigger-form-target='slackConfig']")
    if (slackConfig && !slackConfig.classList.contains("hidden")) {
      this.loadChannelsForCard(card)
    }
  }

  // Populate a card's channel dropdown, fetching the list on first use.
  loadChannelsForCard(card) {
    const select = card.querySelector("[data-trigger-form-target='channelSelect']")
    if (!select || card.dataset.channelsLoaded === "true") return
    card.dataset.channelsLoaded = "true"

    if (!this.slackConfiguredValue) {
      this.setChannelStatus(card, "Slack is not configured (SLACK_BOT_TOKEN is missing). Enter a channel ID manually.", true)
      this.revealManual(card)
      return
    }

    this.setChannelStatus(card, "Loading channels…")
    this.fetchChannels()
      .then((channels) => {
        this.populateChannelSelect(card, channels)
        if (channels.length === 0) {
          this.setChannelStatus(card, "No channels found. The bot may not have been added to any channels yet — you can enter a channel ID manually.", true)
          this.revealManual(card)
        } else {
          this.setChannelStatus(card, `${channels.length} channel${channels.length === 1 ? "" : "s"} available.`)
        }
      })
      .catch((error) => {
        this.setChannelStatus(card, `Couldn't load channels: ${error.message}. Enter a channel ID manually.`, true)
        this.revealManual(card)
      })
  }

  // Fetch (and cache) the channel list. Shared across all cards.
  fetchChannels() {
    if (!this.channelsPromise) {
      this.channelsPromise = fetch(this.channelsUrlValue, { headers: { Accept: "application/json" } })
        .then(async (response) => {
          const data = await response.json().catch(() => ({}))
          if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`)
          return data.channels || []
        })
    }
    return this.channelsPromise
  }

  // Render the fetched channels as <option>s, preserving the current selection.
  populateChannelSelect(card, channels) {
    const select = card.querySelector("[data-trigger-form-target='channelSelect']")
    const channelIdField = card.querySelector("[data-trigger-form-target='channelId']")
    const channelNameField = card.querySelector("[data-trigger-form-target='channelName']")
    if (!select) return

    const currentId = channelIdField ? channelIdField.value : ""
    const sorted = channels.slice().sort((a, b) => a.name.localeCompare(b.name))

    let html = '<option value="">— Select a channel —</option>'
    let found = false
    sorted.forEach((ch) => {
      const selected = ch.id === currentId ? " selected" : ""
      if (ch.id === currentId) found = true
      const prefix = ch.is_private ? "🔒 " : "#"
      html += `<option value="${this.escapeAttr(ch.id)}" data-channel-name="${this.escapeAttr(ch.name)}"${selected}>${prefix}${this.escapeHtml(ch.name)}</option>`
    })

    // Keep a saved channel that is no longer in the accessible list so the
    // existing trigger is not silently reset to blank.
    if (currentId && !found) {
      const savedName = channelNameField ? channelNameField.value : ""
      const label = savedName ? `#${this.escapeHtml(savedName)}` : this.escapeHtml(currentId)
      html += `<option value="${this.escapeAttr(currentId)}" data-channel-name="${this.escapeAttr(savedName)}" selected>${label} (not in accessible list)</option>`
    }

    select.innerHTML = html
  }

  // Sync the hidden channel_id / channel_name fields from the dropdown selection.
  handleChannelSelect(event) {
    const card = event.target.closest("[data-trigger-form-target='conditionCard']")
    if (!card) return

    const option = event.target.selectedOptions[0]
    const channelIdField = card.querySelector("[data-trigger-form-target='channelId']")
    const channelNameField = card.querySelector("[data-trigger-form-target='channelName']")
    const manualInput = card.querySelector("[data-trigger-form-target='channelManualInput']")

    const id = option ? option.value : ""
    const label = option ? (option.dataset.channelName || "") : ""
    if (channelIdField) channelIdField.value = id
    if (channelNameField) channelNameField.value = label
    if (manualInput) manualInput.value = id
  }

  // Toggle the manual channel-ID fallback input.
  toggleChannelManual(event) {
    const card = event.target.closest("[data-trigger-form-target='conditionCard']")
    if (!card) return
    const manual = card.querySelector("[data-trigger-form-target='channelManual']")
    if (!manual) return

    const nowHidden = manual.classList.toggle("hidden")
    if (!nowHidden) {
      const input = manual.querySelector("[data-trigger-form-target='channelManualInput']")
      if (input) input.focus()
    }
  }

  // Sync the hidden channel_id field from the manual input.
  handleChannelManualInput(event) {
    const card = event.target.closest("[data-trigger-form-target='conditionCard']")
    if (!card) return
    const channelIdField = card.querySelector("[data-trigger-form-target='channelId']")
    if (channelIdField) channelIdField.value = event.target.value.trim()
  }

  revealManual(card) {
    const manual = card.querySelector("[data-trigger-form-target='channelManual']")
    if (manual) manual.classList.remove("hidden")
  }

  setChannelStatus(card, message, isError = false) {
    const status = card.querySelector("[data-trigger-form-target='channelStatus']")
    if (!status) return
    status.textContent = message
    status.classList.toggle("text-red-500", isError)
    status.classList.toggle("text-gray-500", !isError)
  }

  escapeHtml(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
  }

  escapeAttr(value) {
    return this.escapeHtml(value).replace(/"/g, "&quot;")
  }

  // Handle schedule mode change (recurring vs one-time) within a condition card
  handleScheduleModeChange(event) {
    const card = event.target.closest("[data-trigger-form-target='conditionCard']")
    if (!card) return

    this.updateScheduleModeInCard(card, event.target.value)
  }

  // Update schedule mode visibility (recurring vs one-time fields) within a specific card.
  // Disables inputs in hidden sections so duplicate-name fields (e.g., timezone) don't
  // submit conflicting values.
  updateScheduleModeInCard(card, mode) {
    const recurringFields = card.querySelector("[data-trigger-form-target='recurringFields']")
    const oneTimeFields = card.querySelector("[data-trigger-form-target='oneTimeFields']")

    if (recurringFields) {
      const hidden = mode !== "recurring"
      recurringFields.classList.toggle("hidden", hidden)
      recurringFields.querySelectorAll("input, select").forEach(el => el.disabled = hidden)
    }
    if (oneTimeFields) {
      const hidden = mode !== "one_time"
      oneTimeFields.classList.toggle("hidden", hidden)
      oneTimeFields.querySelectorAll("input, select").forEach(el => el.disabled = hidden)
    }
  }

  // Handle schedule unit change within a condition card
  handleUnitChange(event) {
    const card = event.target.closest("[data-trigger-form-target='conditionCard']")
    if (!card) return

    this.updateScheduleFieldsInCard(card, event.target.value)
  }

  // Update schedule field visibility based on selected unit within a specific card
  updateScheduleFieldsInCard(card, unit) {
    const dayOfWeekContainer = card.querySelector("[data-trigger-form-target='dayOfWeekContainer']")
    const timeContainer = card.querySelector("[data-trigger-form-target='timeContainer']")
    const timezoneContainer = card.querySelector("[data-trigger-form-target='timezoneContainer']")

    if (dayOfWeekContainer) {
      dayOfWeekContainer.classList.toggle("hidden", unit !== "weeks")
    }

    if (timeContainer) {
      const showTime = ["days", "weeks"].includes(unit)
      timeContainer.classList.toggle("hidden", !showTime)
    }

    if (timezoneContainer) {
      const showTimezone = ["days", "weeks"].includes(unit)
      timezoneContainer.classList.toggle("hidden", !showTimezone)
    }
  }

  // Add a new condition card
  addCondition() {
    const index = this.conditionIndexValue
    this.conditionIndexValue = index + 1

    const template = this.buildConditionTemplate(index)
    this.conditionsContainerTarget.insertAdjacentHTML("beforeend", template)

    this.renumberConditions()
  }

  // Remove a condition card (marks for destruction if persisted, removes from DOM if new)
  removeCondition(event) {
    const card = event.target.closest("[data-trigger-form-target='conditionCard']")
    if (!card) return

    // If there's a destroy field and an [id] hidden input, this is a persisted record - mark for destruction
    const destroyField = card.querySelector("[data-trigger-form-target='destroyField']")
    const idField = card.querySelector("input[name*='[id]'][type='hidden']")
    if (destroyField && idField) {
      destroyField.value = "1"
      card.classList.add("hidden")
    } else {
      card.remove()
    }

    this.renumberConditions()
  }

  // Renumber visible condition cards
  renumberConditions() {
    let num = 1
    this.conditionCardTargets.forEach(card => {
      if (!card.classList.contains("hidden")) {
        const numberEl = card.querySelector("[data-trigger-form-target='conditionNumber']")
        if (numberEl) numberEl.textContent = num
        num++
      }
    })
  }

  // Build HTML template for a new condition card
  buildConditionTemplate(index) {
    const name = `trigger[trigger_conditions_attributes][${index}]`
    return `
      <div class="border border-gray-200 rounded-lg p-4 bg-gray-50" data-trigger-form-target="conditionCard">
        <div class="flex justify-between items-start mb-3">
          <h4 class="text-sm font-medium text-gray-900">Condition #<span data-trigger-form-target="conditionNumber">${index + 1}</span></h4>
          <div class="flex items-center">
            <input type="hidden" name="${name}[_destroy]" value="0" data-trigger-form-target="destroyField">
            <button type="button"
                    data-action="click->trigger-form#removeCondition"
                    class="text-gray-400 hover:text-red-500 text-sm"
                    title="Remove condition">
              <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
              </svg>
            </button>
          </div>
        </div>

        <div class="mb-3">
          <label class="block text-sm font-medium text-gray-700 mb-2">Type <span class="text-red-500">*</span></label>
          <select name="${name}[condition_type]"
                  class="shadow-sm focus:ring-indigo-500 focus:border-indigo-500 block w-full sm:text-sm border-gray-300 rounded-md px-3 py-2 pr-8"
                  data-action="change->trigger-form#handleConditionTypeChange"
                  data-trigger-form-target="conditionTypeSelect">
            <option value="">Select condition type...</option>
            <option value="slack">Slack - Channel messages or @mentions</option>
            <option value="schedule">Schedule - Time-based (recurring or one-time)</option>
            <option value="ao_event">Zimmer Event - Internal system event</option>
          </select>
        </div>

        <div data-trigger-form-target="slackConfig" class="hidden space-y-3">
          <div data-trigger-form-target="slackChannelField">
            <label class="block text-sm font-medium text-gray-700 mb-1">Slack Channel <span class="text-red-500">*</span></label>
            <input type="hidden" name="${name}[configuration][channel_id]" data-trigger-form-target="channelId">
            <input type="hidden" name="${name}[configuration][channel_name]" data-trigger-form-target="channelName">
            <select data-trigger-form-target="channelSelect"
                    data-action="change->trigger-form#handleChannelSelect"
                    class="shadow-sm focus:ring-indigo-500 focus:border-indigo-500 block w-full sm:text-sm border-gray-300 rounded-md px-3 py-2 pr-8">
              <option value="">— Select a channel —</option>
            </select>
            <p data-trigger-form-target="channelStatus" class="mt-1 text-xs text-gray-500"></p>
            <div data-trigger-form-target="channelManual" class="hidden mt-2">
              <input type="text" data-trigger-form-target="channelManualInput" data-action="input->trigger-form#handleChannelManualInput" placeholder="Channel ID (e.g., C0A6BF8T45R)" class="shadow-sm focus:ring-indigo-500 focus:border-indigo-500 block w-full sm:text-sm border-gray-300 rounded-md px-3 py-2">
              <p class="mt-1 text-xs text-gray-500">Enter the channel ID directly. Find it in the channel's details in Slack, or in the channel URL.</p>
            </div>
            <button type="button" data-action="click->trigger-form#toggleChannelManual" class="mt-1 text-xs text-indigo-600 hover:text-indigo-500">Enter channel ID manually</button>
            <p class="mt-1 text-xs text-gray-500">For "Bot mention", leave the channel blank to monitor all channels the bot is in (plus DMs).</p>
          </div>
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">Event Type</label>
            <select name="${name}[configuration][event_type]"
                    class="shadow-sm focus:ring-indigo-500 focus:border-indigo-500 block w-full sm:text-sm border-gray-300 rounded-md px-3 py-2 pr-8">
              <option value="new_message">New message - All messages in channel</option>
              <option value="bot_mention">Bot mention - @mentions and DMs from allowed users</option>
            </select>
            <p class="mt-1 text-xs text-gray-500">Choose how this Slack condition fires. "Bot mention" only processes messages from authorized users.</p>
          </div>
        </div>

        <div data-trigger-form-target="scheduleConfig" class="hidden space-y-3">
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">Schedule Mode <span class="text-red-500">*</span></label>
            <div class="flex gap-4">
              <label class="inline-flex items-center">
                <input type="radio" name="${name}[_schedule_mode]" value="recurring" checked
                       data-trigger-form-target="scheduleModeRadio"
                       data-action="change->trigger-form#handleScheduleModeChange"
                       class="focus:ring-indigo-500 h-4 w-4 text-indigo-600 border-gray-300">
                <span class="ml-2 text-sm text-gray-700">Recurring</span>
              </label>
              <label class="inline-flex items-center">
                <input type="radio" name="${name}[_schedule_mode]" value="one_time"
                       data-trigger-form-target="scheduleModeRadio"
                       data-action="change->trigger-form#handleScheduleModeChange"
                       class="focus:ring-indigo-500 h-4 w-4 text-indigo-600 border-gray-300">
                <span class="ml-2 text-sm text-gray-700">One-time</span>
              </label>
            </div>
          </div>

          <div data-trigger-form-target="recurringFields" class="space-y-3">
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Frequency <span class="text-red-500">*</span></label>
              <div class="flex items-center gap-2">
                <span class="text-sm text-gray-700 font-medium">Every</span>
                <input type="number" name="${name}[configuration][interval]" value="1" min="1" class="shadow-sm focus:ring-indigo-500 focus:border-indigo-500 w-20 sm:text-sm border-gray-300 rounded-md px-3 py-2">
                <select name="${name}[configuration][unit]" data-trigger-form-target="unitSelect" data-action="change->trigger-form#handleUnitChange" class="shadow-sm focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm border-gray-300 rounded-md px-3 py-2 pr-8">
                  <option value="">select...</option>
                  <option value="minutes">minutes</option>
                  <option value="hours">hours</option>
                  <option value="days">days</option>
                  <option value="weeks">weeks</option>
                </select>
              </div>
            </div>

            <div data-trigger-form-target="dayOfWeekContainer" class="hidden">
              <label class="block text-sm font-medium text-gray-700 mb-1">Day of Week <span class="text-red-500">*</span></label>
              <select name="${name}[configuration][day_of_week]" class="shadow-sm focus:ring-indigo-500 focus:border-indigo-500 block w-full sm:text-sm border-gray-300 rounded-md px-3 py-2 pr-8">
                <option value="">Select day...</option>
                <option value="monday">Monday</option>
                <option value="tuesday">Tuesday</option>
                <option value="wednesday">Wednesday</option>
                <option value="thursday">Thursday</option>
                <option value="friday">Friday</option>
                <option value="saturday">Saturday</option>
                <option value="sunday">Sunday</option>
              </select>
            </div>

            <div data-trigger-form-target="timeContainer" class="hidden">
              <label class="block text-sm font-medium text-gray-700 mb-1">Time <span class="text-red-500">*</span></label>
              <input type="time" name="${name}[configuration][time]" class="shadow-sm focus:ring-indigo-500 focus:border-indigo-500 block w-full sm:text-sm border-gray-300 rounded-md px-3 py-2">
            </div>

            <div data-trigger-form-target="timezoneContainer" class="hidden">
              <label class="block text-sm font-medium text-gray-700 mb-1">Timezone</label>
              <select name="${name}[configuration][timezone]" class="shadow-sm focus:ring-indigo-500 focus:border-indigo-500 block w-full sm:text-sm border-gray-300 rounded-md px-3 py-2 pr-8">
                <option value="UTC">UTC</option>
                <option value="Eastern Time (US & Canada)">(GMT-05:00) Eastern Time (US & Canada)</option>
                <option value="Central Time (US & Canada)">(GMT-06:00) Central Time (US & Canada)</option>
                <option value="Mountain Time (US & Canada)">(GMT-07:00) Mountain Time (US & Canada)</option>
                <option value="Pacific Time (US & Canada)">(GMT-08:00) Pacific Time (US & Canada)</option>
              </select>
            </div>
          </div>

          <div data-trigger-form-target="oneTimeFields" class="hidden space-y-3">
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Scheduled Date & Time <span class="text-red-500">*</span></label>
              <input type="datetime-local" name="${name}[configuration][scheduled_at]"
                     data-trigger-form-target="scheduledAtInput"
                     class="shadow-sm focus:ring-indigo-500 focus:border-indigo-500 block w-full sm:text-sm border-gray-300 rounded-md px-3 py-2">
              <p class="mt-1 text-xs text-gray-500">The trigger fires once at this time, then auto-disables.</p>
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Timezone</label>
              <select name="${name}[configuration][timezone]"
                      class="shadow-sm focus:ring-indigo-500 focus:border-indigo-500 block w-full sm:text-sm border-gray-300 rounded-md px-3 py-2 pr-8">
                <option value="UTC">UTC</option>
                <option value="Eastern Time (US & Canada)">(GMT-05:00) Eastern Time (US & Canada)</option>
                <option value="Central Time (US & Canada)">(GMT-06:00) Central Time (US & Canada)</option>
                <option value="Mountain Time (US & Canada)">(GMT-07:00) Mountain Time (US & Canada)</option>
                <option value="Pacific Time (US & Canada)">(GMT-08:00) Pacific Time (US & Canada)</option>
              </select>
            </div>
          </div>
        </div>

        <div data-trigger-form-target="aoEventConfig" class="hidden space-y-3">
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-1">Event <span class="text-red-500">*</span></label>
            <select name="${name}[configuration][event_name]" class="shadow-sm focus:ring-indigo-500 focus:border-indigo-500 block w-full sm:text-sm border-gray-300 rounded-md px-3 py-2 pr-8">
              <option value="">Select event...</option>
              <option value="session_needs_input">Session transitions to needs_input</option>
              <option value="session_failed">Session transitions to failed</option>
              <option value="session_archived">Session archived</option>
            </select>
            <p class="mt-1 text-xs text-gray-500">Fires when an autonomous session transitions to the selected state. Sessions created by this trigger are excluded to prevent loops.</p>
          </div>
        </div>
      </div>
    `
  }
}
