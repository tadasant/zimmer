# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
# Vendored rather than pinned to a CDN. Every other pin here is served by the app,
# and this one was not: the browser fetched it from jsdelivr on every page load, so
# the Ranked queue's inline editing and promote/demote — and the category grid's
# drag-and-drop — went dead whenever that fetch failed. A failed import takes the
# whole controller module with it, so the failure is silent and total rather than
# just "dragging doesn't work". Self-hosted Zimmer should not need a third-party CDN
# to render a working dashboard. Update by re-downloading the same URL into
# vendor/javascript/sortablejs.js.
pin "sortablejs", to: "sortablejs.js" # @1.15.6
pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/lib", under: "lib"
