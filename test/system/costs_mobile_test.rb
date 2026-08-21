require "application_system_test_case"

# The Costs page is a dense stack of number tables — model ids, agent-root names,
# session titles, and a bar chart — which is precisely the shape that runs off the
# right edge of a phone. Nothing fails when it does: the page renders, the tests
# pass, and the browser quietly gives the document a horizontal scroll with the
# figures past the edge.
class CostsMobileTest < ApplicationSystemTestCase
  MOBILE_WIDTH = 375
  MOBILE_HEIGHT = 812

  # Probe 1 sees the document's own overflow. It is blind to a clipping ancestor
  # and to anything `position: fixed`, which is why Probe 2 runs alongside it.
  NO_DOCUMENT_OVERFLOW = <<~JS
    document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1
  JS

  # Probe 2 reads getBoundingClientRect, so it sees straight through a clip — but
  # that also means it sees two things that are not bugs, both of which this app
  # has on every page:
  #
  #   * `position: fixed` panels parked off-canvas on purpose (the follow-up
  #     drawer and the chat bubble sit at `translate-x-full`, `pointer-events-none`
  #     until opened).
  #   * content inside a deliberate horizontal scroller — this page's own window
  #     picker is a `overflow-x-auto` tab strip, which is supposed to run past the
  #     edge and scroll.
  #
  # So it takes a root to scope to, and skips anything whose ancestor scrolls
  # horizontally. What is left is the thing the report was actually about: a
  # control pushed off the edge of the page with no way to reach it.
  ELEMENTS_PAST_RIGHT_EDGE = <<~JS
    (function (selector) {
      const limit = document.documentElement.clientWidth;
      const root = document.querySelector(selector);
      if (!root) { return ["missing root: " + selector]; }

      const insideHorizontalScroller = (el) => {
        for (let p = el.parentElement; p && p !== document.documentElement; p = p.parentElement) {
          const overflowX = getComputedStyle(p).overflowX;
          if (overflowX === "auto" || overflowX === "scroll") { return true; }
        }
        return false;
      };

      return Array.from(root.querySelectorAll("*"))
        .filter((el) => el.getBoundingClientRect().right > limit + 1)
        .filter((el) => !insideHorizontalScroller(el))
        .slice(0, 20)
        .map((el) => `${el.tagName.toLowerCase()}.${el.classList.value} @ ${Math.round(el.getBoundingClientRect().right)}px`);
    })(arguments[0])
  JS

  setup do
    page.driver.browser.manage.window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)
  end

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  def seed_spend!
    session = Session.create!(
      prompt: "Initial prompt", status: :waiting, agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git", branch: "main",
      title: "A deliberately long session title that would set its own container width if nothing truncated it"
    )

    3.times do |i|
      SessionTokenUsage.create!(
        request_id: "req_mobile_#{i}", session_id: session.id,
        # Long unbroken identifiers are signature 4, and Zimmer's UI is made of them.
        model: "claude-opus-4-5-20251101", agent_root: "tadasant-internal/artifacts-agent-roots-issue-work-gate",
        called_at: i.days.ago, input_tokens: 1_000, output_tokens: 250_000,
        cache_read_tokens: 900_000_000, cache_creation_tokens: 40_000_000,
        cache_creation_1h_tokens: 40_000_000
      )
    end

    AdhocTokenUsage.create!(
      request_id: "req_mobile_adhoc", source: "cli_status_probe",
      model: "claude-opus-5", called_at: 1.hour.ago,
      input_tokens: 10, output_tokens: 20, cache_read_tokens: 30_000
    )
  end

  test "the costs page fits a phone, with data and without" do
    # Empty state first: it is the page a fresh deployment sees.
    visit costs_path
    assert_text "No usage recorded"
    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW), "empty Costs page overflows the viewport"
    assert_equal [], page.evaluate_script(ELEMENTS_PAST_RIGHT_EDGE, "#costs-page")

    seed_spend!

    visit costs_path(days: 30)
    assert_text "Where the money goes"

    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW),
      "Costs page overflows the viewport at #{MOBILE_WIDTH}px"
    assert_equal [], page.evaluate_script(ELEMENTS_PAST_RIGHT_EDGE, "#costs-page"),
      "elements extend past the right edge at #{MOBILE_WIDTH}px"

    page.save_screenshot("tmp/screenshots/costs-375.png")
  end

  test "the coverage panel and its button fit a phone, error text and all" do
    seed_spend!
    # A sweep in flight, stuck on the kind of error the ledger actually stores:
    # a class name and a file path, with nothing to break on. Signature 4.
    TokenUsageBackfill.create!(
      transcript_root: "/home/rails/.claude/projects",
      started_at: 20.minutes.ago, last_ran_at: 1.minute.ago,
      directories_total: 3_182, directories_done: 914,
      last_error: "Errno::EACCES: Permission denied @ rb_sysopen - " \
                  "/home/rails/.claude/projects/-home-rails--zimmer-clones-zimmer-main-1786989710-abcdef12/" \
                  "0f3c9d21-6b4e-4a77-9a11-5c2f7de91b40.jsonl"
    )

    visit costs_path(days: 30)
    assert_text "Backfilling history"
    assert_text "Sweep now"

    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW),
      "the coverage panel overflows the viewport at #{MOBILE_WIDTH}px"
    assert_equal [], page.evaluate_script(ELEMENTS_PAST_RIGHT_EDGE, "#costs-page"),
      "the coverage panel pushes something past the right edge at #{MOBILE_WIDTH}px"

    page.save_screenshot("tmp/screenshots/costs-coverage-375.png")
  end

  test "the sessions index nav still fits a phone with Costs added to it" do
    visit root_path
    assert_selector "a[href='#{costs_path}']", visible: :all

    # Only the document-width probe here. This diff added two links to a nav it
    # does not otherwise own, so asserting that nothing on the whole sessions
    # index sticks out would be asserting about pre-existing chrome — and would
    # fail on the off-canvas drawer and chat bubble the layout parks past the
    # right edge on every page by design.
    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW),
      "sessions index overflows the viewport at #{MOBILE_WIDTH}px"
  end

  test "the costs page also fits the narrowest phone still in use" do
    seed_spend!
    page.driver.browser.manage.window.resize_to(320, 800)

    visit costs_path(days: 30)
    assert_text "Where the money goes"

    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW), "Costs page overflows at 320px"
    assert_equal [], page.evaluate_script(ELEMENTS_PAST_RIGHT_EDGE, "#costs-page")
  end
end
