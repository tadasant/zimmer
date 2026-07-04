import { Controller } from "@hotwired/stimulus"

// Character counter controller for textareas with a maximum length limit
// Shows real-time character count and changes appearance when approaching/exceeding the limit
//
// Usage:
//   <div data-controller="character-counter" data-character-counter-max-value="500000">
//     <textarea data-character-counter-target="input" data-action="input->character-counter#update"></textarea>
//     <div data-character-counter-target="counter"></div>
//   </div>
//
// The counter will show:
// - Gray text when under 80% of limit
// - Yellow text when 80-100% of limit
// - Red text with warning styling when over limit
export default class extends Controller {
  static targets = ["input", "counter"]
  static values = {
    max: { type: Number, default: 500000 }
  }

  connect() {
    // Guard against connecting when required targets are missing.
    // This can happen during Turbo Stream replacements when elements with
    // data-turbo-permanent are being moved around in the DOM.
    // The controller will be reconnected once all targets are available.
    if (!this.hasInputTarget || !this.hasCounterTarget) {
      return
    }
    this.update()
  }

  update() {
    // Safety check in case targets are missing during DOM manipulation
    if (!this.hasInputTarget || !this.hasCounterTarget) {
      return
    }
    const currentLength = this.inputTarget.value.length
    const maxLength = this.maxValue
    const remaining = maxLength - currentLength
    const percentage = (currentLength / maxLength) * 100

    // Format numbers with commas for readability
    const formatNumber = (num) => num.toLocaleString()

    // Update the counter text
    this.counterTarget.textContent = `${formatNumber(currentLength)} / ${formatNumber(maxLength)} characters`

    // Remove all state classes first
    this.counterTarget.classList.remove(
      "text-gray-500", "text-yellow-600", "text-red-600", "font-semibold"
    )
    this.inputTarget.classList.remove(
      "border-yellow-400", "border-red-500", "ring-red-500", "focus:ring-red-500", "focus:border-red-500"
    )

    if (currentLength > maxLength) {
      // Over limit - red and bold
      this.counterTarget.classList.add("text-red-600", "font-semibold")
      this.inputTarget.classList.add("border-red-500", "ring-red-500", "focus:ring-red-500", "focus:border-red-500")
    } else if (percentage >= 80) {
      // Approaching limit - yellow
      this.counterTarget.classList.add("text-yellow-600")
      this.inputTarget.classList.add("border-yellow-400")
    } else {
      // Normal - gray
      this.counterTarget.classList.add("text-gray-500")
    }
  }
}
