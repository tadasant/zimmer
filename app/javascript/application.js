// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
//
// Imported ahead of Turbo deliberately: this binds the `turbo:frame-missing`
// listener that keeps Turbo's "Content missing" placeholder off the screen, and it
// has to be listening before the first frame can finish a fetch.
import "lib/frame_missing_recovery"
import "@hotwired/turbo-rails"
import "controllers"
// Shows a mutating Turbo submission's outcome at the click and puts it back on a
// refusal; see the module for which submissions and why.
import "lib/optimistic_actions"
// Hands a broadcast-rendered form the page's CSRF token, which it cannot carry itself;
// see the module.
import "lib/form_token_fill"

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
