require "application_system_test_case"

# Drag-and-drop attachment on the message composer.
#
# The regression these pin is a *geometry* one, not a handler one: the drop
# listeners used to live on a div wrapping only the textarea, so a file dropped on
# the button row -- inside what anyone would call the composer -- reached no handler,
# nothing called preventDefault, and the browser navigated the tab to the file.
# So every drop below is aimed at an element deliberately OUTSIDE the textarea, and
# each one asserts on `defaultPrevented` as well as on the resulting preview: a drop
# the page did not claim is the bug, whether or not an upload happens to follow.
class ComposerDragDropTest < ApplicationSystemTestCase
  # For the phone-width case below. The resting composer is already covered by
  # MobileHorizontalOverflowTest; what is new here is the drop overlay, which only
  # exists while a drag is in flight and so is a state that test cannot reach.
  include MobileOverflowAssertions

  # A real 1x1 PNG. The upload endpoint validates the bytes, so a placeholder
  # string would be rejected server-side and the preview would stay empty for a
  # reason that has nothing to do with the drop.
  ONE_PIXEL_PNG_BASE64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  test "an image dropped on the composer button row attaches" do
    session = create_session
    visit session_path(session)
    wait_for_stimulus_controller("composer-drop")

    prevented = drop_files_on(
      '[data-image-attachment-target="attachButton"]',
      [ png_file("dropped.png") ]
    )

    assert prevented, "the composer did not claim a file dropped on its button row"
    assert_selector '[data-image-attachment-target="preview"]', text: "1 image"
  end

  test "a non-image file dropped on the composer panel attaches" do
    session = create_session
    visit session_path(session)
    wait_for_stimulus_controller("composer-drop")

    prevented = drop_files_on(
      '[data-follow-up-prompt-target="submitButton"]',
      [ text_file("notes.txt") ]
    )

    assert prevented, "the composer did not claim a file dropped on its submit button"
    assert_selector '[data-file-attachment-target="preview"]', text: "notes.txt"
  end

  test "the drop overlay follows a file drag and survives crossing onto a child" do
    session = create_session
    visit session_path(session)
    wait_for_stimulus_controller("composer-drop")

    assert_selector '[data-composer-drop-target="overlay"].hidden', visible: :all

    # dragenter/dragleave fire once per element crossed and bubble to the document,
    # so entering a child while leaving its parent is the sequence that used to
    # clear the highlight mid-drag.
    page.execute_script(<<~JS)
      window.__dt = new DataTransfer()
      window.__dt.items.add(new File(["x"], "a.txt", { type: "text/plain" }))
      const fire = (el, type) => el.dispatchEvent(
        new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: window.__dt })
      )
      const textarea = document.querySelector("textarea[name='follow_up_prompt']")
      fire(document.body, "dragenter")
      fire(textarea, "dragenter")
      fire(document.body, "dragleave")
    JS

    assert_no_selector '[data-composer-drop-target="overlay"].hidden', visible: :all

    page.execute_script(<<~JS)
      const textarea = document.querySelector("textarea[name='follow_up_prompt']")
      textarea.dispatchEvent(
        new DragEvent("dragleave", { bubbles: true, cancelable: true, dataTransfer: window.__dt })
      )
    JS

    assert_selector '[data-composer-drop-target="overlay"].hidden', visible: :all
  end

  test "a drag carrying no files is left alone for the enqueued-message reorder" do
    session = create_session
    visit session_path(session)
    wait_for_stimulus_controller("composer-drop")

    # The reorder is an internal HTML5 drag: its dataTransfer has no "Files" entry.
    # composer-drop must not preventDefault it and must not show its overlay, or the
    # reorder's own handlers stop seeing the events they are bound to.
    result = page.evaluate_script(<<~JS)
      (() => {
        const dt = new DataTransfer()
        dt.setData("text/plain", "enqueued-message-1")
        const panel = document.querySelector("[data-controller~='composer-drop']")
        const prevented = ["dragenter", "dragover", "drop"].map((type) => {
          const event = new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: dt })
          panel.dispatchEvent(event)
          return event.defaultPrevented
        })
        const overlay = document.querySelector("[data-composer-drop-target='overlay']")
        return { prevented, overlayHidden: overlay.classList.contains("hidden") }
      })()
    JS

    assert_equal [ false, false, false ], result["prevented"],
      "composer-drop swallowed a non-file drag, which would break enqueued-message reordering"
    assert result["overlayHidden"], "the drop overlay appeared for a drag carrying no files"
  end

  test "a file dropped on the new session form attaches to the initial prompt" do
    visit new_session_path
    wait_for_stimulus_controller("composer-drop")

    prevented = drop_files_on(
      '[data-file-attachment-target="attachButton"]',
      [ text_file("spec.md") ]
    )

    assert prevented, "the new session form did not claim a file dropped on its button row"
    assert_selector '[data-file-attachment-target="preview"]', text: "spec.md"
  end

  test "the drop overlay does not push the composer off a phone screen" do
    page.driver.browser.manage.window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)

    session = create_session
    visit session_path(session)
    wait_for_stimulus_controller("composer-drop")
    # The composer lives behind a collapsed drawer on a phone, and the overlay is
    # inside it — measuring it collapsed would measure nothing.
    find("[data-bottom-drawer-target='trigger'] button").click

    page.execute_script(<<~JS)
      const dt = new DataTransfer()
      dt.items.add(new File(["x"], "a.txt", { type: "text/plain" }))
      document.body.dispatchEvent(
        new DragEvent("dragenter", { bubbles: true, cancelable: true, dataTransfer: dt })
      )
    JS

    assert_no_selector '[data-composer-drop-target="overlay"].hidden', visible: :all
    assert_no_horizontal_overflow("session detail with the composer drop overlay showing")
  ensure
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  private

  def create_session
    Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
  end

  def png_file(name)
    { name: name, type: "image/png", base64: ONE_PIXEL_PNG_BASE64 }
  end

  def text_file(name)
    { name: name, type: "text/plain", text: "dropped file contents\n" }
  end

  # Synthesize the external-file drag a browser produces and aim it at `selector`.
  # Returns whether the page claimed the drop -- `drop.defaultPrevented`, which is
  # what decides between "attached" and "the browser navigates to the file".
  def drop_files_on(selector, files)
    prevented = page.evaluate_script(<<~JS, selector, files.map { |f| f.transform_keys(&:to_s) })
      ((selector, specs) => {
        const dt = new DataTransfer()
        for (const spec of specs) {
          const body = spec.base64
            ? Uint8Array.from(atob(spec.base64), (c) => c.charCodeAt(0))
            : spec.text
          dt.items.add(new File([body], spec.name, { type: spec.type }))
        }
        const target = document.querySelector(selector)
        for (const type of ["dragenter", "dragover"]) {
          target.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: dt }))
        }
        const drop = new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: dt })
        target.dispatchEvent(drop)
        return drop.defaultPrevented
      })(arguments[0], arguments[1])
    JS
    prevented
  end
end
