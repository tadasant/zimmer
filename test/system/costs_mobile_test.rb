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

  # Probe 2 reads getBoundingClientRect, so it sees straight through a clip.
  ELEMENTS_PAST_RIGHT_EDGE = <<~JS
    (function () {
      const limit = document.documentElement.clientWidth;
      return Array.from(document.querySelectorAll("*"))
        .filter((el) => el.getBoundingClientRect().right > limit + 1)
        .slice(0, 20)
        .map((el) => `${el.tagName.toLowerCase()}.${el.classList.value} @ ${Math.round(el.getBoundingClientRect().right)}px`);
    })()
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
    assert_equal [], page.evaluate_script(ELEMENTS_PAST_RIGHT_EDGE)

    seed_spend!

    visit costs_path(days: 30)
    assert_text "Where the money goes"

    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW),
      "Costs page overflows the viewport at #{MOBILE_WIDTH}px"
    assert_equal [], page.evaluate_script(ELEMENTS_PAST_RIGHT_EDGE),
      "elements extend past the right edge at #{MOBILE_WIDTH}px"

    page.save_screenshot("tmp/screenshots/costs-375.png")
  end

  test "the sessions index nav still fits a phone with Costs added to it" do
    visit root_path
    assert_selector "a[href='#{costs_path}']", visible: :all

    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW),
      "sessions index overflows the viewport at #{MOBILE_WIDTH}px"
    assert_equal [], page.evaluate_script(ELEMENTS_PAST_RIGHT_EDGE),
      "elements extend past the right edge at #{MOBILE_WIDTH}px"
  end

  test "the costs page also fits the narrowest phone still in use" do
    seed_spend!
    page.driver.browser.manage.window.resize_to(320, 800)

    visit costs_path(days: 30)
    assert_text "Where the money goes"

    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW), "Costs page overflows at 320px"
    assert_equal [], page.evaluate_script(ELEMENTS_PAST_RIGHT_EDGE)
  end
end
