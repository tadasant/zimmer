import { Controller } from "@hotwired/stimulus"

/**
 * CodeBlockController - Enhances code blocks within markdown content
 *
 * This controller automatically finds code blocks (<pre><code>) within its
 * element and adds interactive features like copy buttons.
 *
 * Designed to be extensible for future features like:
 * - Syntax highlighting toggles
 * - Code block expansion/collapse
 * - Line number toggles
 * - Download as file
 *
 * Usage:
 *   <div data-controller="code-block">
 *     <%= markdown(content) %>
 *   </div>
 */
export default class extends Controller {
  connect() {
    // Track buttons and their handlers for cleanup
    this.buttonHandlers = new Map()
    // Track feedback timeouts for cleanup
    this.feedbackTimeouts = new Map()

    this.enhanceCodeBlocks()

    // Set up a MutationObserver to handle dynamically added code blocks
    // Only process when new nodes containing <pre> elements are added
    this.observer = new MutationObserver((mutations) => {
      const hasNewCodeBlocks = mutations.some(mutation =>
        Array.from(mutation.addedNodes).some(node =>
          node.nodeType === Node.ELEMENT_NODE &&
          (node.tagName === "PRE" || node.querySelector?.("pre"))
        )
      )
      if (hasNewCodeBlocks) {
        this.enhanceCodeBlocks()
      }
    })
    this.observer.observe(this.element, { childList: true, subtree: true })
  }

  disconnect() {
    // Clean up MutationObserver
    if (this.observer) {
      this.observer.disconnect()
    }

    // Clean up event listeners to prevent memory leaks
    this.buttonHandlers.forEach((handler, button) => {
      button.removeEventListener("click", handler)
    })
    this.buttonHandlers.clear()

    // Clean up any pending timeouts
    this.feedbackTimeouts.forEach(timeout => clearTimeout(timeout))
    this.feedbackTimeouts.clear()
  }

  enhanceCodeBlocks() {
    // Find all <pre> elements that contain <code> - these are fenced code blocks
    const preElements = this.element.querySelectorAll("pre")

    preElements.forEach(pre => {
      // Skip if already enhanced
      if (pre.dataset.enhanced === "true") return

      // Mark as enhanced to avoid duplicate processing
      pre.dataset.enhanced = "true"

      // Create wrapper div for positioning
      const wrapper = document.createElement("div")
      wrapper.className = "code-block-wrapper group relative"

      // Wrap the pre element
      pre.parentNode.insertBefore(wrapper, pre)
      wrapper.appendChild(pre)

      // Add the copy button
      this.addCopyButton(wrapper, pre)
    })
  }

  addCopyButton(wrapper, preElement) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = [
      "code-copy-button",
      "absolute",
      "bottom-2",
      "right-2",
      "p-1.5",
      "rounded-md",
      "text-gray-400",
      "hover:text-gray-200",
      "opacity-0",
      "group-hover:opacity-100",
      "focus:opacity-100",
      "focus:outline-none",
      "focus:ring-2",
      "focus:ring-white/30",
      "transition-all",
      "duration-200"
    ].join(" ")
    // Add inline styles for the backdrop blur and subtle background
    button.style.cssText = "background: rgba(255, 255, 255, 0.08); backdrop-filter: blur(4px); -webkit-backdrop-filter: blur(4px);"

    button.appendChild(this.createCopyIcon())
    button.title = "Copy code"
    button.setAttribute("aria-label", "Copy code to clipboard")

    // Create handler and track it for cleanup
    const clickHandler = (event) => {
      event.preventDefault()
      this.copyCode(preElement, button)
    }
    button.addEventListener("click", clickHandler)
    this.buttonHandlers.set(button, clickHandler)

    wrapper.appendChild(button)
  }

  async copyCode(preElement, button) {
    // Get the code content from the <code> element within <pre>, or the <pre> itself
    const codeElement = preElement.querySelector("code")
    const text = (codeElement || preElement).textContent

    try {
      await navigator.clipboard.writeText(text)
      this.showCopiedFeedback(button)
    } catch (err) {
      console.error("Failed to copy code:", err)
      // Fallback for older browsers
      this.fallbackCopy(text, button)
    }
  }

  fallbackCopy(text, button) {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()

    try {
      document.execCommand("copy")
      this.showCopiedFeedback(button)
    } catch (err) {
      console.error("Fallback copy failed:", err)
    }

    document.body.removeChild(textarea)
  }

  showCopiedFeedback(button) {
    // Cancel any existing timeout for this button to handle rapid clicks
    if (this.feedbackTimeouts.has(button)) {
      clearTimeout(this.feedbackTimeouts.get(button))
    }

    // Replace icon with checkmark and update style
    button.innerHTML = ""
    button.appendChild(this.createCheckIcon())
    button.classList.add("text-green-400")
    button.classList.remove("text-gray-400")
    button.style.background = "rgba(34, 197, 94, 0.15)"

    // Reset after 2 seconds
    const timeout = setTimeout(() => {
      button.innerHTML = ""
      button.appendChild(this.createCopyIcon())
      button.classList.remove("text-green-400")
      button.classList.add("text-gray-400")
      button.style.background = "rgba(255, 255, 255, 0.08)"
      this.feedbackTimeouts.delete(button)
    }, 2000)

    this.feedbackTimeouts.set(button, timeout)
  }

  // Create copy icon using DOM methods (safer than innerHTML)
  createCopyIcon() {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
    svg.setAttribute("class", "h-4 w-4")
    svg.setAttribute("fill", "none")
    svg.setAttribute("viewBox", "0 0 24 24")
    svg.setAttribute("stroke", "currentColor")
    svg.setAttribute("stroke-width", "2")

    const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
    path.setAttribute("stroke-linecap", "round")
    path.setAttribute("stroke-linejoin", "round")
    path.setAttribute("d", "M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z")

    svg.appendChild(path)
    return svg
  }

  // Create checkmark icon using DOM methods (safer than innerHTML)
  createCheckIcon() {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
    svg.setAttribute("class", "h-4 w-4")
    svg.setAttribute("fill", "none")
    svg.setAttribute("viewBox", "0 0 24 24")
    svg.setAttribute("stroke", "currentColor")
    svg.setAttribute("stroke-width", "2")

    const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
    path.setAttribute("stroke-linecap", "round")
    path.setAttribute("stroke-linejoin", "round")
    path.setAttribute("d", "M5 13l4 4L19 7")

    svg.appendChild(path)
    return svg
  }
}
