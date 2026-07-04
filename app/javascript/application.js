// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// Prevent Turbo Stream updates from replacing elements that are being edited.
// When a turbo-frame has data-editing="true" (set by editable-title controller),
// skip the replace so the user's input isn't blown away by a live update.
document.addEventListener("turbo:before-stream-render", (event) => {
  const stream = event.target
  if (stream.getAttribute("action") !== "replace") return

  const targetId = stream.getAttribute("target")
  const targetElement = document.getElementById(targetId)
  if (targetElement && targetElement.getAttribute("data-editing") === "true") {
    event.preventDefault()
  }
})
