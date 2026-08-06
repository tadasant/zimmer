require "application_system_test_case"

# A prompt typed into the composer but not yet submitted has to survive the page
# being rebuilt underneath it.
#
# Two things rebuild it in practice, and the user cannot tell them apart: iOS
# discards a backgrounded standalone PWA's web view under memory pressure, so
# reopening the app performs a fresh navigation; and Zimmer itself reloads a
# session screen that comes back visible with a dead ActionCable connection
# (stream_visibility_recovery_controller.js). Both end in the same place — a
# fresh document, an empty textarea.
#
# A forced reload is the faithful proxy for both. A true iOS cold relaunch
# cannot be driven from headless Chrome, but it is the same DOM-is-gone
# situation, and it is the reason the draft lives in localStorage rather than
# sessionStorage: a relaunched PWA gets a new browsing session, so sessionStorage
# would already be empty by the time anything read it.
class FollowUpDraftPersistenceTest < ApplicationSystemTestCase
  PHONE_VIEWPORT = [ 390, 844 ].freeze

  def create_session
    Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
  end

  # Type into whichever textarea the layout is actually showing, the way a user
  # does — real input events, so the debounced save runs.
  def type_draft(text)
    textarea = find(:css, "textarea[name='follow_up_prompt'], textarea[name='follow_up_prompt_mobile']", match: :first, visible: true)
    textarea.send_keys(text)
    textarea
  end

  def visible_composer_value
    page.evaluate_script(<<~JS)
      (function() {
        const areas = document.querySelectorAll("textarea[name='follow_up_prompt'], textarea[name='follow_up_prompt_mobile']");
        for (const a of areas) { if (a.offsetParent !== null) return a.value }
        return areas.length ? areas[0].value : null
      })()
    JS
  end

  def stored_draft_keys
    page.evaluate_script("Object.keys(window.localStorage).filter((k) => k.startsWith('zimmerDraft:'))")
  end

  # Reload the way a reopened PWA does, then wait for the composer to settle so
  # the assertion isn't racing Stimulus' connect-time restore.
  def reload_and_settle
    page.refresh
    open_transcript_panel
    assert_selector "textarea[name='follow_up_prompt']", visible: :all
  end

  test "typed follow-up prompt survives a page reload" do
    session = create_session
    visit session_path(session)

    type_draft("half-written follow-up I do not want to lose")

    # The draft has to be written down *while typing*, not by the reload.
    assert_not_empty stored_draft_keys_eventually(expect: :present),
      "expected the draft to be persisted while typing, before any reload"

    reload_and_settle

    assert_composer_value "half-written follow-up I do not want to lose"
  end

  test "typed follow-up prompt survives a reload at a phone viewport" do
    # The bug this guards: restore used to fill only the desktop textarea, so on
    # a phone — where the mobile textarea is the visible one — the text was in
    # storage but the user saw an empty box.
    page.driver.browser.manage.window.resize_to(*PHONE_VIEWPORT)
    session = create_session
    visit session_path(session)

    type_draft("typed on a phone")
    assert_not_empty stored_draft_keys_eventually(expect: :present)

    reload_and_settle

    assert_composer_value "typed on a phone"
  ensure
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  test "draft is written when the page is hidden without waiting for the debounce" do
    session = create_session
    visit session_path(session)

    textarea = type_draft("backgrounded mid-sentence")

    # Simulate the OS taking the app away immediately after a keystroke, before
    # the debounce timer would have fired.
    page.execute_script(<<~JS)
      Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true })
      document.dispatchEvent(new Event("visibilitychange"))
    JS

    stored = page.evaluate_script(<<~JS)
      (function() {
        const key = Object.keys(window.localStorage).find((k) => k.startsWith("zimmerDraft:"))
        return key ? JSON.parse(window.localStorage.getItem(key)).value : null
      })()
    JS

    assert_equal "backgrounded mid-sentence", stored
    assert_equal "backgrounded mid-sentence", textarea.value
  end

  test "drafts do not bleed between sessions" do
    first = create_session
    second = create_session

    visit session_path(first)
    type_draft("meant for the first session")
    assert_not_empty stored_draft_keys_eventually(expect: :present)

    visit session_path(second)
    assert_composer_value ""

    visit session_path(first)
    assert_composer_value "meant for the first session"
  end

  test "submitting clears the draft so it is not restored afterwards" do
    session = create_session
    visit session_path(session)

    type_draft("a message that gets sent")
    assert_not_empty stored_draft_keys_eventually(expect: :present)

    click_button "Send Message"
    assert_text "a message that gets sent"

    # Nothing should be left behind for the next load to restore.
    assert_empty stored_draft_keys_eventually,
      "expected the draft to be cleared after a successful submit"

    reload_and_settle
    assert_composer_value ""
  end

  test "clearing the textarea clears the draft rather than restoring stale text" do
    session = create_session
    visit session_path(session)

    textarea = type_draft("typed then thought better of it")
    assert_not_empty stored_draft_keys_eventually(expect: :present)

    # Select-all + delete, the way a user abandons a draft.
    textarea.send_keys([ :control, "a" ], :backspace)

    assert_empty stored_draft_keys_eventually,
      "expected an emptied composer to clear the draft, not persist an empty string"

    reload_and_settle
    assert_composer_value ""
  end

  test "an expired draft is discarded rather than restored" do
    session = create_session
    visit session_path(session)

    # Plant a draft stamped well past the 7-day expiry.
    page.execute_script(<<~JS)
      const key = "zimmerDraft:session:#{session.id}:followUpPrompt"
      const eightDaysAgo = Date.now() - (8 * 24 * 60 * 60 * 1000)
      window.localStorage.setItem(key, JSON.stringify({ value: "ancient draft", savedAt: eightDaysAgo }))
    JS

    reload_and_settle

    assert_composer_value ""
    assert_empty stored_draft_keys_eventually, "expected the expired draft to be pruned from storage"
  end

  private

  # Draft writes are debounced and the connect-time restore runs asynchronously,
  # so poll rather than asserting on the first read.
  def assert_composer_value(expected, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    actual = visible_composer_value
    while actual != expected && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep 0.1
      actual = visible_composer_value
    end
    assert_equal expected, actual
  end

  # Poll until the stored draft keys reach the expected shape. `expect: :absent`
  # waits for them to drain (after a submit or a cleared textarea), `:present`
  # waits for the debounced write to land.
  def stored_draft_keys_eventually(expect: :absent, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    settled = ->(keys) { expect == :absent ? keys.empty? : keys.any? }
    keys = stored_draft_keys
    until settled.call(keys) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.1
      keys = stored_draft_keys
    end
    keys
  end
end
