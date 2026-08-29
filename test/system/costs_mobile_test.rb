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

    # Feature attribution rides on the same rows, so the feature table and the
    # per-root drilldown have something to render at this width too.
    SessionTokenUsage.find_each do |record|
      %w[goal mcp_result skill_body].each_with_index do |feature, index|
        TokenUsageFeature.create!(
          request_id: record.request_id, feature: feature, session_id: record.session_id,
          agent_root: record.agent_root, model: record.model, called_at: record.called_at,
          cache_read_tokens: 100_000_000 / (index + 1), chars: 10_000, occurrences: 1
        )
      end
    end
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

  test "the calendar range is reachable and usable on a phone" do
    # The picker is the control most likely to run off the edge: two date inputs
    # and a submit button in a row, at the width where a row of three stops fitting.
    seed_spend!
    visit costs_path(days: 30)

    assert_selector "#costs-from"
    assert_selector "#costs-to"
    assert_equal [], page.evaluate_script(ELEMENTS_PAST_RIGHT_EDGE, "form[action='#{costs_path}']")

    from = 3.days.ago.to_date
    to = Date.current

    # Date objects, not their iso8601 strings. Capybara sets an `<input type=date>`
    # from a Date through the value property; hand it a String and it falls back to
    # typing the characters into the field's segments, which land in whatever order
    # the browser's locale puts them. The strings this test used to pass produced a
    # range in the year 828 — a window the page rendered happily, and nothing here
    # looked closely enough to notice.
    fill_in "from", with: from
    fill_in "to", with: to
    click_button "Apply"

    # Apply is a full page load (the form is `turbo: false`), so wait for the new
    # document before touching the DOM at all. `assert_current_path` reads the
    # driver's URL rather than resolving an element, which is what makes it the one
    # wait here that cannot observe a node from the outgoing document.
    #
    # The old wait was `assert_text "Showing"` — and "Showing" is on the page
    # *before* Apply too, so it matched the outgoing document and let everything
    # below it race the swap.
    assert_current_path costs_path(from: from.iso8601, to: to.iso8601)

    # Now that the range that came back can be named, name it: the picker is only
    # "usable" if the days it submits are the days it applies.
    assert_text "Showing #{CostWindow.custom(from, to).label}"
    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW), "custom range overflows at #{MOBILE_WIDTH}px"

    page.save_screenshot("tmp/screenshots/costs-calendar-375.png")
  end

  test "the chart and the breakdown rows open their detail on a tap" do
    # Hover is invisible on a phone. Both drilldowns have to work from a tap, so
    # both are asserted with a plain click at the phone width.
    seed_spend!
    visit costs_path(days: 30)
    assert_text "Daily spend"

    bars = all("[data-cost-chart-target='bar']")
    assert_operator bars.length, :>, 1, "need at least two days to prove the readout changes"

    # The chart opens on the most recent day; tapping the first bar must move the
    # readout to the oldest one. Asserted through the panel's own visibility
    # rather than through page text, since the dates also appear on the axis.
    assert_equal 1, all("[data-cost-chart-target='panel']", visible: true).length
    bars.first.click
    assert_selector "[data-cost-chart-target='bar'][data-active='true']", count: 1
    assert_equal bars.first[:"aria-label"].split(":").first,
      find("[data-cost-chart-target='panel']", visible: true).text.lines.first.strip

    row = first("details > summary")
    row.click
    assert_selector "details[open]"
    assert_text "Estimated context-feature split"

    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW), "an opened drilldown overflows at #{MOBILE_WIDTH}px"
    assert_equal [], page.evaluate_script(ELEMENTS_PAST_RIGHT_EDGE, "#costs-page")

    page.save_screenshot("tmp/screenshots/costs-drilldown-375.png")
  end

  test "the muted session cost fits the card and the detail page" do
    seed_spend!

    visit root_path
    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW),
      "the dashboard overflows at #{MOBILE_WIDTH}px with the cost badge added"

    visit session_path(Session.order(:id).last)
    assert_text "$"
    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW),
      "the session detail page overflows at #{MOBILE_WIDTH}px with the cost indicator added"
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
  # Cohort-tagged sessions on both sides of the setting, with a root that ran on
  # both so the paired drilldown has a row to open.
  def seed_cohorts!
    %w[off on].each_with_index do |cohort, side|
      6.times do |i|
        session = Session.create!(
          prompt: "p", status: :waiting, agent_runtime: "claude_code",
          git_root: "https://github.com/test/repo.git", branch: "main", title: "#{cohort}-#{i}"
        )
        SessionExperimentalFlag.create!(
          session: session, setting_key: "mcp_tool_search",
          value_at_start: cohort == "on", value_at_end: cohort == "on",
          source: SessionExperimentalFlag::BACKFILLED
        )
        10.times do |call|
          SessionTokenUsage.create!(
            request_id: "req_#{cohort}_#{i}_#{call}", session_id: session.id,
            model: "claude-opus-4-5-20251101",
            agent_root: "tadasant-internal/artifacts-agent-roots-issue-work-gate",
            called_at: 2.hours.ago, input_tokens: 1_000,
            output_tokens: 250_000 / (side + 1), cache_read_tokens: 900_000_000 / (side + 1)
          )
        end
      end
    end
  end

  test "the experiment report fits a phone, cohort cards and paired roots and all" do
    # Two stat cards side by side and a per-root comparison row carrying a long
    # agent-root name: signature 1 (a grid child that will not shrink) and
    # signature 4 (an unbreakable string) in the same section.
    seed_cohorts!

    visit costs_path(days: 30)
    assert_text "Experimental settings"
    assert_text "MCP tool search"

    find("summary", text: "Same agent root").click
    assert_text "Only roots that ran on both sides"

    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW),
      "the experiment report overflows the viewport at #{MOBILE_WIDTH}px"
    assert_equal [], page.evaluate_script(ELEMENTS_PAST_RIGHT_EDGE, "#costs-page"),
      "the experiment report pushes something past the right edge at #{MOBILE_WIDTH}px"

    page.save_screenshot("tmp/screenshots/costs-experiments-375.png")

    # And at the narrowest phone still in use, where the cohort cards are the
    # first thing that would stop fitting.
    page.driver.browser.manage.window.resize_to(320, 800)
    visit costs_path(days: 30)
    assert_text "MCP tool search"
    assert page.evaluate_script(NO_DOCUMENT_OVERFLOW), "the experiment report overflows at 320px"
    assert_equal [], page.evaluate_script(ELEMENTS_PAST_RIGHT_EDGE, "#costs-page")
  end
end
