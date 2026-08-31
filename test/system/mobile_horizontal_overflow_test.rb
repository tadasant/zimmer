require "application_system_test_case"

# Horizontal overflow is the failure mode phone users actually report: a control
# runs past the right edge and is either unreachable or forces the whole page to
# scroll sideways. It is also trivially easy to reintroduce — one `flex` row that
# cannot wrap, or one long unbreakable token (a session id, a branch name, a
# `bin/rails ...` snippet) in a column without `min-w-0`, and the page is wide again.
#
# So this asserts the invariant directly, per page, at a phone width: the document
# never scrolls sideways, and no control is clipped past an overflow-hidden
# ancestor. It is deliberately about geometry rather than about any one utility
# class, so a future refactor that keeps the page usable keeps the test green.
class MobileHorizontalOverflowTest < ApplicationSystemTestCase
  MOBILE_WIDTH = 375
  MOBILE_HEIGHT = 812

  setup do
    page.driver.browser.manage.window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)
  end

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  # A title with no break opportunity is the hardest case for the session grid,
  # so every fixture below carries one.
  LONG_TOKEN_TITLE = "Fix flaky test_session_state_machine_transitions_from_waiting_to_running".freeze

  def create_session(**overrides)
    Session.create!({
      title: LONG_TOKEN_TITLE,
      prompt: "Investigate the failure and land a fix.",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "feature/a-fairly-long-branch-name-for-overflow-testing"
    }.merge(overrides))
  end

  # The agent root a hierarchy node is identified by. Stamped after create because
  # it lives in metadata the model owns rather than in an attribute.
  def with_agent_root(session, key)
    session.update!(metadata: (session.metadata || {}).merge("agent_root_key" => key))
    session
  end

  def create_trigger
    trigger = Trigger.new(
      name: "nightly-catalog-resolve-and-cache-warm",
      prompt_template: "Resolve the AIR catalog and warm the cache.",
      status: "enabled",
      agent_root_name: AgentRootsConfig.all.first.name
    )
    trigger.trigger_conditions.build(
      condition_type: "schedule",
      configuration: { "unit" => "hours", "interval" => 6, "timezone" => "UTC" }
    )
    trigger.save!
    trigger
  end

  # Returns [document_overflow_px, [clipped control descriptions]].
  def overflow_report
    page.evaluate_script(<<~JS)
      (function () {
        const W = document.documentElement.clientWidth;
        const clipped = [];
        document.querySelectorAll("button, a, input, select, textarea, summary, table, h1, h2, h3, code, pre").forEach((el) => {
          const cs = getComputedStyle(el);
          if (cs.display === "none" || cs.visibility === "hidden") return;
          const b = el.getBoundingClientRect();
          if (b.width === 0 || b.height === 0) return;
          let p = el.parentElement, clipper = null;
          while (p && p !== document.documentElement) {
            const s = getComputedStyle(p);
            if (s.overflowX === "hidden" || s.overflowX === "clip") { clipper = p; break; }
            p = p.parentElement;
          }
          if (!clipper) return;
          const cut = Math.round(b.right - clipper.getBoundingClientRect().right);
          if (cut > 1) {
            clipped.push(cut + "px past its container: <" + el.tagName.toLowerCase() + "> " +
              JSON.stringify((el.innerText || el.value || "").trim().slice(0, 40)));
          }
        });
        return [document.documentElement.scrollWidth - W, clipped];
      })()
    JS
  end

  def assert_no_horizontal_overflow(label)
    doc_overflow, clipped = overflow_report

    assert doc_overflow <= 0,
      "#{label} scrolls sideways at #{MOBILE_WIDTH}px: the document is #{doc_overflow}px wider than the viewport."
    assert_empty clipped,
      "#{label} has controls clipped out of reach at #{MOBILE_WIDTH}px:\n  #{clipped.join("\n  ")}"
  end

  test "sessions index does not overflow horizontally on a phone" do
    create_session(status: :failed)
    create_session(title: "Short one", status: :needs_input)

    visit root_path
    assert_text "Short one"

    assert_no_horizontal_overflow("sessions index")

    # The Filters section is the densest block in the phone-width sidebar: a wrapping
    # row of five status pills, a segmented scheduling-class control, and — behind the
    # Advanced disclosure — the widest inputs on the page. The disclosure's contents
    # are display:none until it is open, so a closed <details> would prove nothing
    # about them.
    page.execute_script("document.querySelector('details').open = true")
    assert_no_horizontal_overflow("sessions index with Filters > Advanced open")

    # A multi-status selection must not widen it either — the pills have to wrap.
    check "status-filter-failed", allow_label_click: true
    click_on "Apply filters"
    assert_text LONG_TOKEN_TITLE

    assert_no_horizontal_overflow("sessions index with a multi-status filter applied")
  end

  # The transcript-scan notice is new markup on the busiest page, and it is the one
  # element on it whose text is a full sentence rather than a label — so it is the
  # shape most likely to widen the results header on a phone.
  test "the transcript-scan notice does not overflow horizontally on a phone" do
    create_session(title: "Kestrel session", status: :needs_input,
      transcript: [ { "type" => "assistant", "message" => { "content" => "the kestrel manoeuvre worked" } } ])

    visit root_path(q: "kestrel manoeuvre", search_contents: "1", status: Session.statuses.keys)
    assert_text "Transcript scan complete"

    assert_no_horizontal_overflow("sessions index with a completed transcript scan")
    scroll_to_scan_notice
    page.save_screenshot(Rails.root.join("tmp/screenshots/content-scan-complete-375.png").to_s)

    # A budget of zero forces the "stopped early" branch, which is the amber notice
    # and the one a phone reader most needs to be able to read in full.
    previous = ENV["ZIMMER_CONTENT_SEARCH_BUDGET_SECONDS"]
    ENV["ZIMMER_CONTENT_SEARCH_BUDGET_SECONDS"] = "0"
    begin
      visit root_path(q: "kestrel manoeuvre", search_contents: "1", status: Session.statuses.keys)
      assert_text "Transcript scan stopped early"

      assert_no_horizontal_overflow("sessions index with an incomplete transcript scan")
      scroll_to_scan_notice
      page.save_screenshot(Rails.root.join("tmp/screenshots/content-scan-incomplete-375.png").to_s)
    ensure
      ENV["ZIMMER_CONTENT_SEARCH_BUDGET_SECONDS"] = previous
      ENV.delete("ZIMMER_CONTENT_SEARCH_BUDGET_SECONDS") if previous.nil?
    end
  end

  # save_screenshot captures the viewport, and the notice sits below the phone-width
  # filter sidebar — so the evidence has to be scrolled to before it is taken.
  def scroll_to_scan_notice
    page.execute_script(<<~JS)
      const el = Array.from(document.querySelectorAll("div"))
        .find((d) => /Transcript scan/.test(d.textContent) && d.children.length === 0);
      if (el) el.scrollIntoView({ block: "center" });
    JS
  end

  test "session detail does not overflow horizontally on a phone" do
    session = create_session

    visit session_path(session)
    assert_text LONG_TOKEN_TITLE

    assert_no_horizontal_overflow("session detail")
  end

  # The approval banner is the densest row on the session page: three action
  # buttons in one flex row, above a request summary that is one unbreakable
  # `tool_name: message` string. A non-wrapping row puts Dismiss off the edge.
  #
  # The two banners are checked on separate sessions because they cannot coexist:
  # a live elicitation clears any lost-elicitation marker on its session.
  test "a live approval banner does not overflow horizontally on a phone" do
    session = create_session(status: :running)
    Elicitation.create!(
      session: session,
      request_id: "req-#{SecureRandom.hex(8)}",
      mode: "form",
      message: "Reveal the production database password for the staging migration?",
      requested_schema: { "type" => "object", "properties" => { "environment" => { "type" => "string" } } },
      meta: {},
      tool_name: "op_read",
      expires_at: 1.hour.from_now
    )

    visit session_path(session)
    assert_text "Action Approval Required"

    assert_no_horizontal_overflow("session detail with an approval banner")
  end

  test "a lost-elicitation banner does not overflow horizontally on a phone" do
    session = create_session(status: :needs_input, metadata: {
      "lost_elicitation" => {
        "reason" => "stranded",
        "at" => Time.current.iso8601,
        "request_id" => "req-abc123",
        "summary" => "op_read: Reveal the production database password for the staging migration"
      }
    })

    visit session_path(session)
    assert_text "Approval request lost"

    assert_no_horizontal_overflow("session detail with a lost-elicitation banner")
  end

  # The session hierarchy panel is the one place on this page where the two
  # assertions above are not enough. Each node is an agent-root badge, a title,
  # an `#id · status`, a genesis pill and sometimes an uncle pill on a single
  # line, indented a further 20px per level of nesting — and when that ran past
  # the right edge the document reported no sideways scroll at all, so the tail
  # of a node was not merely off screen but unreachable (issue #390).
  #
  # `getBoundingClientRect` measures where an element actually is, whatever an
  # ancestor does with the overflow, which is why this compares against the
  # viewport directly rather than reusing `overflow_report`.
  #
  # Returns the offending elements described the way the mobile QA pass's Probe 2
  # describes them.
  def elements_past_right_edge(selector)
    page.evaluate_script(<<~JS)
      (function () {
        const limit = document.documentElement.clientWidth;
        const root = document.querySelector(#{selector.to_json});
        if (!root) return ["no element matched " + #{selector.to_json}];
        return Array.from(root.querySelectorAll("*"))
          .filter((el) => el.getBoundingClientRect().right > limit + 1)
          .slice(0, 20)
          .map((el) => el.tagName.toLowerCase() + "." + el.classList.value +
                       " @ " + Math.round(el.getBoundingClientRect().right) + "px");
      })()
    JS
  end

  # The computed `padding-left` of the node marked as the current session — the
  # depth indent, which is 8px per level below `sm:` and 20px per level above it.
  def current_node_indent(list_selector)
    page.evaluate_script(
      "getComputedStyle(document.querySelector(#{"#{list_selector} > li[data-current]".to_json})).paddingLeft"
    )
  end

  # A title is legible only if it is not visually cut off, which a `truncate` would
  # be while still passing every measurement above. On a flex item — which every
  # node's title is — scrollWidth and clientWidth are real numbers, so their
  # difference is the part of the title the reader cannot see.
  def assert_title_not_clipped(element, label)
    clipped = page.evaluate_script(
      "arguments[0].scrollWidth - arguments[0].clientWidth", element.native
    )
    assert clipped <= 1, "#{label} is clipped by #{clipped}px instead of wrapping"
  end

  test "session hierarchy nodes stay within the viewport on a phone, unchanged at desktop width" do
    origin = with_agent_root(
      create_session(title: "Gate and claim the mobile overflow bug", status: :needs_input),
      "zimmer-router"
    )
    router = with_agent_root(
      create_session(
        title: "Implement zimmer#390 (session hierarchy nodes overflow at 375px)",
        status: :needs_input, parent_session_id: origin.id
      ),
      "zimmer-router"
    )
    # Keeps LONG_TOKEN_TITLE, so the link path renders an unbreakable title.
    worker = with_agent_root(create_session(status: :needs_input, parent_session_id: router.id), "zimmer")
    helper = with_agent_root(
      create_session(title: "Check the Safari case too", status: :needs_input, parent_session_id: worker.id),
      "zimmer"
    )
    # Depth 4 of MAX_DEPTH 8, so the indent is well past the point where a phone
    # row would have run out — and it keeps LONG_TOKEN_TITLE, so the current-node
    # path renders an unbreakable title too.
    current = with_agent_root(create_session(status: :running, parent_session_id: helper.id), "zimmer")
    # The uncle is a sibling rather than an ancestor. An uncle edge is walked
    # downward like a spawn edge, so an uncle nearer the root would re-seat the
    # current session at a shallower depth and quietly change the indent this
    # test is measuring.
    sibling = with_agent_root(
      create_session(title: "Re-route the stalled worker", status: :needs_input, parent_session_id: helper.id),
      "zimmer-router"
    )
    SessionUncleLink.create!(session: current, uncle_session: sibling, source: "test")

    list = "#session_#{current.id}_hierarchy"

    visit session_path(current)
    assert_text "Session hierarchy"
    within(list) { assert_text "also senior" }
    # The deepest node is the current one, and it carries every pill the panel can
    # render — so this is the widest row in the widest tree the fixture builds.
    assert_selector "#{list} > li[data-current][data-depth='4']"
    # Captured before the assertions so a failing run uploads the broken layout too.
    # Scrolled into view first: a screenshot is of the viewport, and the panel sits
    # below the fold on a phone.
    scroll_into_center(find(list))
    page.save_screenshot("tmp/screenshots/proof-session-hierarchy-375.png")

    # Deliberately first: the document not scrolling sideways is exactly what made
    # this bug invisible to the page-level check, so run that check and then the
    # per-element one it cannot see.
    assert_no_horizontal_overflow("session detail with a hierarchy")

    past_edge = elements_past_right_edge(list)
    assert_empty past_edge,
      "hierarchy nodes end past the #{MOBILE_WIDTH}px viewport, out of reach:\n  #{past_edge.join("\n  ")}"

    assert_equal "32px", current_node_indent(list), "the depth indent should be 8px per level on a phone"

    # Both title paths, each holding the unbreakable token that would otherwise set
    # its own container's width: a link on another node, a span on the current one.
    assert_title_not_clipped(find("#{list} a", text: LONG_TOKEN_TITLE, match: :first), "a linked node title")
    assert_title_not_clipped(find("#{list} span.font-semibold", text: LONG_TOKEN_TITLE), "the current node title")

    # And the laptop is unchanged: full 20px-per-level indent, nothing past the edge.
    page.driver.browser.manage.window.resize_to(1400, 900)
    visit session_path(current)
    assert_text "Session hierarchy"

    assert_empty elements_past_right_edge(list), "hierarchy nodes end past the 1400px viewport"
    assert_equal "80px", current_node_indent(list),
      "the depth indent should be the unchanged 20px per level at desktop width"
  end

  # The Quick Router's spot opt-in is a checkbox with a two-line explanation beside
  # it — the description-column-next-to-a-fixed-control shape that overflows the
  # moment the description stops shrinking. It ships on three surfaces, two of them
  # phone-only, and the panel one is what the mobile joystick's Quick Router petal
  # opens, so a phone is the primary way it gets used rather than an afterthought.
  test "the Quick Router spot opt-in is on screen and reachable on a phone" do
    visit root_path
    assert_selector "[data-controller='quick-prompt']"

    # Surface 1: the dashboard's full-screen mobile prompt overlay.
    find("button[data-action='quick-prompt#openMobile']").click
    assert_selector "#quick_prompt_mobile_scheduling_class", visible: true

    mobile_box = find("#quick_prompt_mobile_scheduling_class")
    assert_not mobile_box.checked?, "the spot opt-in must default to off — priority is the default"
    page.save_screenshot("tmp/screenshots/proof-quick-router-spot-mobile-overlay-375.png")

    # Only the per-element probe here, deliberately. The overlay is `fixed inset-0`
    # and locks the page behind it with `body { overflow: hidden }` while it is
    # open, so `overflow_report` would walk every element on the dashboard up to a
    # body that now clips — reporting the view-mode tab strip (legitimately
    # `overflow-x-auto`) and the off-canvas notes drawer as clipped controls. The
    # unobstructed dashboard is already covered by the first test in this file;
    # what this one has to prove is that the overlay's own contents fit.
    past_edge = elements_past_right_edge("[data-quick-prompt-target='mobileOverlay']")
    assert_empty past_edge,
      "the mobile overlay's spot opt-in ends past the #{MOBILE_WIDTH}px viewport, out of reach:\n  #{past_edge.join("\n  ")}"

    # It ticks, and it un-ticks again when the overlay is closed: the choice is
    # per-submission, not a sticky preference the next prompt silently inherits.
    mobile_box.click
    assert mobile_box.checked?
    find("button[data-action='quick-prompt#closeMobile']").click
    find("button[data-action='quick-prompt#openMobile']").click
    assert_not find("#quick_prompt_mobile_scheduling_class").checked?,
      "reopening the overlay should start back at the default"
    find("button[data-action='quick-prompt#closeMobile']").click

    # Surface 2: the chat-bubble Quick Router panel, which is also what the mobile
    # joystick's quick-router petal opens (joystick_menu#_openChatBubble clicks this
    # same FAB), so proving the panel proves the petal.
    find("#chat-bubble button[aria-label='Open quick router']").click
    # Wait for the panel's open END-STATE class, not just for the checkbox to be
    # findable. The panel slides in from `translate-x-full` — parked entirely off
    # the right edge — over 200ms, and WebDriver's displayedness algorithm ignores
    # the `opacity-0` it travels with, so the checkbox reads as displayed while the
    # panel is still off screen. Probing then would measure the panel where it
    # started rather than where it lands.
    assert_selector "[data-chat-bubble-target='panel'].translate-x-0.opacity-100"
    assert_selector "[data-chat-bubble-target='spot']", visible: true

    bubble_box = find("[data-chat-bubble-target='spot']")
    assert_not bubble_box.checked?, "the panel's spot opt-in must default to off too"
    page.save_screenshot("tmp/screenshots/proof-quick-router-spot-chat-bubble-375.png")

    # Per-element only, for the same reason as the overlay above and one more: the
    # panel is `position: fixed`, so it contributes nothing to the document's
    # scrollable overflow and a page-level scrollWidth check cannot see it at all.
    panel_past_edge = elements_past_right_edge("[data-chat-bubble-target='panel']")
    assert_empty panel_past_edge,
      "the Quick Router panel ends past the #{MOBILE_WIDTH}px viewport, out of reach:\n  #{panel_past_edge.join("\n  ")}"

    # The geometry above proves the control is reachable; this proves it is wired.
    # The panel submits over `fetch` rather than as a form, so the checkbox only
    # reaches the server if `chat_bubble#_submit` reads it — the exact "renders but
    # is dropped" failure the controller tests guard from the other side.
    bubble_box.click
    assert bubble_box.checked?

    # Closing the panel drops the choice, however it was closed. The draft text is
    # kept on purpose and the class is not: re-ticking a box is cheap, and a stale
    # tick would silently park a later prompt behind the quota gate.
    find("[data-chat-bubble-target='panel'] button[aria-label='Close']").click
    find("#chat-bubble button[aria-label='Open quick router']").click
    assert_selector "[data-chat-bubble-target='panel'].translate-x-0.opacity-100"
    assert_not find("[data-chat-bubble-target='spot']").checked?,
      "reopening the panel should start back at the default"

    find("[data-chat-bubble-target='spot']").click
    find("[data-chat-bubble-target='textarea']").fill_in with: "Sweep the catalog for dangling references"
    find("[data-chat-bubble-target='submitButton']").click
    # The panel slides back out only on a successful create — on an error it stays
    # open with the error line — so its closed end-state is a sync point with no
    # timing window, unlike the success badge, which hides itself after 2.5s.
    #
    # `visible: :all` because this asserts a CLASS, not visibility: the closed panel
    # carries `opacity-0 pointer-events-none` alongside `translate-x-full`, so
    # Capybara's default visibility filter rejects the very state being asserted.
    # The error line is checked too, so a create that failed reports itself here
    # rather than as a confusing miss on the row read below.
    assert_selector "[data-chat-bubble-target='panel'].translate-x-full", visible: :all
    assert_selector "[data-chat-bubble-target='error'].hidden", visible: :all

    created = Session.where("prompt LIKE ?", "%Sweep the catalog for dangling references%").last
    assert created, "the Quick Router panel did not create a session"
    assert_equal SessionGenesis::SPOT, created.scheduling_class,
      "the panel's spot opt-in did not reach the server"
    assert_equal SessionGenesis::WEB_UI, created.genesis

    # Surface 3 is the dashboard's inline desktop prompt row, hidden below `md:`.
    # Check it at a laptop width, where it is the last item in the attach-button row
    # and therefore the one that would land off the edge if the row could not hold it.
    page.driver.browser.manage.window.resize_to(1400, 900)
    visit root_path
    assert_selector "#quick_prompt_desktop_scheduling_class", visible: true
    assert_not find("#quick_prompt_desktop_scheduling_class").checked?
    assert_empty elements_past_right_edge("[data-quick-prompt-target='desktopForm']"),
      "the desktop prompt row's spot opt-in ends past the 1400px viewport"
  end

  test "new session form does not overflow horizontally on a phone" do
    visit new_session_path
    assert_selector "form"

    assert_no_horizontal_overflow("new session form")
  end

  test "settings does not overflow horizontally on a phone" do
    visit settings_path
    assert_text "Session Defaults"

    assert_no_horizontal_overflow("settings")
  end

  # The Experimental section is a description column beside a fixed-width switch —
  # the shape that overflows the moment the description stops shrinking. The MCP
  # tool search row carries the longest copy in the section, so it is the one that
  # would push the switch off the right edge.
  test "the experimental MCP tool search toggle is on screen and reachable on a phone" do
    AppSetting.delete_all

    visit settings_path
    assert_text "Experimental"
    assert_text "MCP tool search is"

    toggle = find("#app_setting_mcp_tool_search_enabled", visible: :all)
    assert toggle.checked?, "MCP tool search should render ON by default"

    # Captured before the assertions so a failing run uploads the broken layout too.
    scroll_into_center(find("#experimental-settings"))
    page.save_screenshot("tmp/screenshots/proof-settings-experimental-375.png")

    assert_no_horizontal_overflow("settings with the experimental section")

    # Probe 2: the switch is a fixed-width box at the end of the row, so measure
    # where it actually is rather than trusting the document not to scroll.
    past_edge = elements_past_right_edge("#experimental-settings")
    assert_empty past_edge,
      "the experimental section ends past the #{MOBILE_WIDTH}px viewport, out of reach:\n  #{past_edge.join("\n  ")}"
  ensure
    AppSetting.delete_all
  end

  test "triggers index and detail do not overflow horizontally on a phone" do
    trigger = create_trigger

    visit triggers_path
    assert_text trigger.name
    assert_no_horizontal_overflow("triggers index")

    visit trigger_path(trigger)
    assert_text "Run Now"
    assert_no_horizontal_overflow("trigger detail")
  end

  # A failed trigger renders an error string it did not choose — an exception
  # message with no break opportunity is the normal case, not the pathological
  # one. Both surfaces show it, so both are measured with one in place.
  UNBREAKABLE_ERROR = "AgentRootsConfig::AgentRootNotFoundError: " \
    "agent_root_name=zimmer-production-deploy-and-verify-nightly-catalog-resolve not found in catalog".freeze

  test "a failed trigger's error does not overflow horizontally on a phone" do
    trigger = create_trigger
    trigger.mark_failed(UNBREAKABLE_ERROR)

    visit triggers_path
    assert_text "Failed"
    assert_no_horizontal_overflow("triggers index with a failed trigger")
    # Uploaded by CI on success too (see the workflow's screenshot step) — an agent
    # session has no local Postgres, so this is where a PR's UI evidence comes from.
    page.save_screenshot("tmp/screenshots/proof-triggers-index-failed-375.png")

    visit trigger_path(trigger)
    assert_text "This trigger failed to fire"
    assert_no_horizontal_overflow("trigger detail with a failed trigger")
    assert_button "Re-arm"
    page.save_screenshot("tmp/screenshots/proof-trigger-detail-failed-375.png")
  end

  # The account card only crowds once several accounts are listed, and the email is
  # the token that has to wrap — so this owns both rather than leaning on fixtures.
  # The readings matter too: with them the spot gate renders its live decision and
  # the pool note under it, which is the longest prose on the page.
  test "quotas does not overflow horizontally on a phone" do
    AppSetting.editable.update!(spot_gating_enabled: true,
                                spot_reserve_five_hour_pct: 20,
                                spot_reserve_weekly_pct: 20)
    3.times do |i|
      account = ClaudeAccount.create!(
        email: "a-rather-long-account-address-#{i}@subdomain.example.com",
        status: 0,
        priority: i
      )
      ClaudeAccountQuotaSnapshot.create!(
        claude_account: account, utilization_5h: 0.90 - (i * 0.4), utilization_7d: 0.20,
        reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now,
        active_session_count: 1, trigger: "usage_sample"
      )
    end

    visit quotas_path
    assert_selector "h1"
    assert_selector "#spot-gate-pool-note"

    assert_no_horizontal_overflow("quotas")
  end

  # The spot gate's genesis rows are the screen this suite exists for: the table's
  # Action column is the only control there, and it does not fit a phone, so below
  # `sm` the rows render as stacked cards with the button on screen. The card sits
  # on Quotas, beside the windows it reads.
  test "spot gate genesis controls are reachable on a phone" do
    visit quotas_path
    assert_text "Sessions no trigger started"

    kind = SessionGenesis::SETTABLE_KINDS.first
    assert_selector "#genesis-card-#{kind.key}", visible: true
    assert_selector "#genesis-row-#{kind.key}", visible: :hidden

    within "#genesis-card-#{kind.key}" do
      button = find("input[type=submit], button", match: :first)
      # The layout viewport is narrower than the window once a scrollbar is taken
      # out, so measure against clientWidth rather than the resize_to width.
      right_edge = page.evaluate_script(
        "arguments[0].getBoundingClientRect().right", button.native
      )
      viewport = page.evaluate_script("document.documentElement.clientWidth")
      assert right_edge <= viewport,
        "genesis action button ends at #{right_edge}px, past the #{viewport}px viewport"
    end
  end

  test "health dashboard does not overflow horizontally on a phone" do
    visit health_dashboard_path
    assert_selector "h1"

    assert_no_horizontal_overflow("health dashboard")
  end

  # The auth card grows a second line when the pool is recovering — every account
  # still labelled quota_exceeded while its own newer reading says it can serve.
  # That line is the longest string on the card, so it is the one that would push
  # the card past the edge.
  test "health dashboard auth card does not overflow while the pool is recovering" do
    ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME)
      .update_all(status: ClaudeAccount.statuses[:quota_exceeded])
    ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).find_each do |account|
      account.quota_snapshots.create!(trigger: "rotation", status_5h: "allowed", status_7d: "allowed",
        utilization_5h: 0.35, reset_5h: 26.minutes.from_now,
        utilization_7d: 0.12, reset_7d: 6.days.from_now)
    end

    visit health_dashboard_path
    assert_text "serviceable on their own readings"

    assert_no_horizontal_overflow("health dashboard (pool recovering)")
  end

  # The retry-budget panel is a five-row list of counter keys — `signal_death_retry_count`
  # is 24 unbreakable characters — next to a four-up figure grid. Both are the shapes that
  # run off a phone, and the panel renders whether or not any budget has been spent.
  test "the retry budget panel does not overflow horizontally on a phone" do
    create_session(status: :running, metadata: {
      "mcp_retry_count" => 1, "mcp_last_retry_at" => 2.hours.ago.iso8601
    })
    create_session(status: :failed, metadata: {
      "compact_retry_count" => 2, "last_compact_at" => 3.hours.ago.iso8601
    })
    create_session(status: :failed, metadata: {
      "signal_death_retry_count" => 3, "last_signal_death_at" => 90.minutes.ago.iso8601
    })

    visit health_dashboard_path
    assert_text "Retry Budgets"
    # All five, including the three no health surface reported before #527.
    RetryBudget.all.each { |budget| assert_text budget.key }

    assert_no_horizontal_overflow("health dashboard (retry budgets)")

    # Captured as PR evidence — scrolled to the panel, since a viewport screenshot
    # of a page this long otherwise shows only the header.
    page.execute_script("document.evaluate(\"//h3[text()='Retry Budgets']\", document, null, 9, null).singleNodeValue.scrollIntoView()")
    page.save_screenshot("tmp/screenshots/health-retry-budgets-375.png")
  end

  test "CLI tools does not overflow horizontally on a phone" do
    visit clis_path
    assert_selector "h1"

    assert_no_horizontal_overflow("CLI tools")
  end

  test "connectors does not overflow horizontally on a phone" do
    visit connectors_path
    assert_selector "h1"

    assert_no_horizontal_overflow("connectors")
  end

  test "notifications does not overflow horizontally on a phone" do
    visit notifications_path
    assert_selector "h1"

    assert_no_horizontal_overflow("notifications")
  end

  # The Outcomes ledger is the widest table Zimmer ships: eight columns, two
  # action buttons on the right of every row, and titles that are long unbreakable
  # strings. The action buttons being the LAST column is what makes this the exact
  # shape of the original report — a Analyze button that runs off the right edge.
  test "the outcomes ledger, drilldown and stats do not overflow horizontally on a phone" do
    analyzed = create_session(status: :archived, archived_at: 1.day.ago)
    with_agent_root(analyzed, AgentRootsConfig.all.first.name)
    unanalyzed = create_session(title: "Short one", status: :archived, archived_at: 2.days.ago)
    OutcomeAnalyses::Save.call(session: analyzed, root: outcome_tree)

    visit outcomes_path
    assert_text "Short one"
    assert_no_horizontal_overflow("outcomes ledger")
    # The action buttons are the LAST column, so they only stay on screen because
    # the metadata columns collapse below their breakpoints. If those come back at
    # phone width, Analyze goes back off the right edge behind a sideways scroll.
    # Regexes, not strings: the headers are rendered through `uppercase`, so
    # Capybara sees "SESSION". A case-sensitive `assert_no_selector` would pass
    # against a visible "HARNESS" and prove nothing.
    assert_selector "th", text: /session/i
    assert_no_selector "th", text: /harness/i
    assert_no_selector "th", text: /created/i
    assert_selector "button", text: "Analyze", exact_text: true

    visit outcome_path(analyzed.id)
    assert_selector "[data-segment-id]"
    assert_no_horizontal_overflow("outcomes drilldown")

    visit outcomes_stats_path
    assert_selector "h1"
    assert_no_horizontal_overflow("outcome stats")

    assert unanalyzed.reload.archived?
  end

  # A root Segment with one failed and one successful child — the shape the ledger
  # and the flamegraph both have to render.
  def outcome_tree
    {
      "id" => "S0",
      "trigger" => { "kind" => "New", "source" => "user" },
      "goal" => { "text" => LONG_TOKEN_TITLE, "kind" => "Action" },
      "outcome" => { "kind" => "Success", "explanation" => "Landed after one failed patch." },
      "meta" => {},
      "children" => [
        { "id" => "S0.0", "trigger" => { "kind" => "New", "source" => "agent" },
          "goal" => { "text" => "Patch the state machine", "kind" => "Action" },
          "outcome" => { "kind" => "Failure", "explanation" => "Patch did not compile; reverted." },
          "meta" => {}, "children" => [] },
        { "id" => "S0.1", "trigger" => { "kind" => "Correction", "source" => "user" },
          "goal" => { "text" => "Read the failing spec first", "kind" => "Plan" },
          "outcome" => { "kind" => "Success", "explanation" => "Found the missing guard." },
          "meta" => {}, "children" => [] }
      ]
    }
  end

  # The Ranked view is the operator's queue screen, and the densest list Zimmer
  # renders: a drag handle, an editable rank, a status pill, an unbreakable title
  # and an actions menu, on one row, forty times over. Its "⋮" menu is absolutely
  # positioned and its rows sit near the right edge, so Probe 1 alone would wave
  # the menu through — hence the per-element pass over the opened menu too.
  test "the ranked queue and its row menus stay within the viewport on a phone" do
    queued = Session.create!(
      title: LONG_TOKEN_TITLE, prompt: "Investigate the failure and land a fix.",
      status: :waiting, git_root: "https://github.com/test/repo.git",
      scheduling_class: SessionGenesis::SPOT, precedence: 123_456
    )
    top = with_agent_root(
      Session.create!(
        title: "Ship the hotfix", prompt: "x", status: :running,
        git_root: "https://github.com/test/repo.git",
        scheduling_class: SessionGenesis::PRIORITY, precedence: 0
      ),
      "zimmer-router"
    )

    visit root_path(view: SessionsController::VIEW_MODE_RANKED)
    assert_selector "#ranked_row_#{queued.id}"

    scroll_into_center(find("#ranked_sessions"))
    page.save_screenshot("tmp/screenshots/proof-ranked-queue-375.png")

    assert_no_horizontal_overflow("ranked queue")
    past_edge = elements_past_right_edge("#ranked_sessions")
    assert_empty past_edge,
      "ranked rows end past the #{MOBILE_WIDTH}px viewport, out of reach:\n  #{past_edge.join("\n  ")}"

    # A phone wraps the title instead of truncating it, so the unbreakable token
    # is readable rather than cut off mid-word.
    assert_title_not_clipped(find("#ranked_row_#{queued.id} a", text: LONG_TOKEN_TITLE), "a ranked row title")

    # The row's only control is the menu, and it has to be a thumb-sized target.
    kebab = find("#ranked_row_#{top.id} button[aria-label='More actions for session #{top.id}']")
    assert kebab.native.size.height >= 36, "the ⋮ target is only #{kebab.native.size.height}px tall"
    kebab.click
    assert_button "Demote to spot"
    page.save_screenshot("tmp/screenshots/proof-ranked-row-menu-375.png")

    assert_no_horizontal_overflow("ranked queue with a row menu open")
    past_edge = elements_past_right_edge("#ranked_sessions")
    assert_empty past_edge,
      "an open row menu ends past the #{MOBILE_WIDTH}px viewport:\n  #{past_edge.join("\n  ")}"

    # A row that ARRIVED over the stream has to be as narrow as one the server
    # rendered — it is built from the same partial, but it is inserted by
    # JavaScript into a list the server never sized for it, and the operator
    # reading this screen on a phone is the person who would find out otherwise.
    find("body").click # close the menu without navigating
    arrival = Session.create!(
      title: LONG_TOKEN_TITLE, prompt: "x", status: :running,
      git_root: "https://github.com/test/repo.git",
      scheduling_class: SessionGenesis::SPOT, precedence: 654_321
    )
    assert_selector "#ranked_row_#{arrival.id}", wait: 5
    page.save_screenshot("tmp/screenshots/proof-ranked-live-insert-375.png")

    assert_no_horizontal_overflow("ranked queue after a row arrived over the stream")
    past_edge = elements_past_right_edge("#ranked_sessions")
    assert_empty past_edge,
      "a row inserted by a broadcast ends past the #{MOBILE_WIDTH}px viewport:\n  #{past_edge.join("\n  ")}"
    assert_title_not_clipped(find("#ranked_row_#{arrival.id} a", text: LONG_TOKEN_TITLE),
      "a live-inserted ranked row title")

    # And the laptop keeps the single-line row it had: rank, status, title, root.
    page.driver.browser.manage.window.resize_to(1400, 900)
    visit root_path(view: SessionsController::VIEW_MODE_RANKED)
    assert_selector "#ranked_row_#{queued.id}"

    assert_empty elements_past_right_edge("#ranked_sessions"),
      "ranked rows end past the 1400px viewport"
    # The laptop's row is still one line with a truncated title — the phone layout
    # is `max-sm:` only, so a fix for the phone cannot have restyled the desktop.
    assert_equal "nowrap", page.evaluate_script(
      "getComputedStyle(document.querySelector(#{"#ranked_row_#{queued.id} a".to_json})).whiteSpace"
    ), "the desktop row should still truncate its title on one line"
    page.save_screenshot("tmp/screenshots/proof-ranked-queue-1400.png")
  end

  # A card footer is one wrapping flex row: the PR button on the left, the actions
  # (overflow menu, Trash, View) pushed right. Nothing overflows when it wraps -- the
  # row just becomes two rows and the card grows a line, which is what "the buttons
  # stack" looks like on a phone. Neither probe above can see that, so it gets its own
  # geometry assertion: the PR button shares a line with the first action button.
  #
  # This is a guard on the phone-width budget rather than a regression pin. What the
  # button's label may contain is pinned in test/system/github_pr_tracking_test.rb;
  # this holds the line if some future addition to the footer spends the slack.
  test "a session card's PR button shares the footer's line with the action buttons on a phone" do
    url = "https://github.com/owner/repo/pull/603"
    session = create_session(status: :needs_input)
    session.update!(custom_metadata: {
      "github_pull_request_urls" => [ url ],
      "github_pull_request_statuses" => { url => "open" },
      "github_pull_request_ci_statuses" => { url => "pass" }
    })

    visit root_path
    assert_selector "a[href='#{url}']"

    assert_no_horizontal_overflow("sessions index with a PR button")

    # Measured against the first action button, not against the action group as a
    # whole: that group wraps internally too, and a group whose own second row
    # dragged its centre down would fail this while the PR button sat exactly where
    # it belongs -- blaming the PR button for someone else's wrap.
    overlap = page.evaluate_script(<<~JS)
      (function () {
        const link = document.querySelector("a[href='#{url}']");
        const row = link.closest("div.justify-between");
        if (!row) return "no footer row: the card markup this test reads has moved";
        if (row.children.length !== 2) {
          return "expected the footer row to hold 2 groups, found " + row.children.length;
        }
        const first = row.children[1].firstElementChild;
        if (!first) return "the action group is empty";
        const a = link.getBoundingClientRect(), b = first.getBoundingClientRect();
        return a.bottom > b.top && a.top < b.bottom;
      })()
    JS

    assert_equal true, overlap,
      "the PR button did not share the footer's line with the first action button " \
      "at #{MOBILE_WIDTH}px (#{overlap})"
  end

  # The desktop layout has to keep working: these same pages are read on a laptop,
  # and `flex-wrap` / stacked-on-mobile fixes are exactly the kind of change that
  # silently reflows a wide screen.
  test "fixed pages still lay out without overflow at desktop width" do
    create_session
    trigger = create_trigger
    page.driver.browser.manage.window.resize_to(1400, 900)

    [ root_path, new_session_path, settings_path, triggers_path, trigger_path(trigger),
      quotas_path, health_dashboard_path, clis_path, connectors_path,
      notifications_path, outcomes_path, outcomes_stats_path ].each do |path|
      visit path
      doc_overflow, = overflow_report
      assert doc_overflow <= 0, "#{path} scrolls sideways at 1400px (#{doc_overflow}px too wide)"
    end
  end
end
