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
    create_session(title: "Short one", status: :waiting)

    visit root_path
    assert_text "Short one"

    assert_no_horizontal_overflow("sessions index")
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
  test "quotas does not overflow horizontally on a phone" do
    3.times do |i|
      ClaudeAccount.create!(
        email: "a-rather-long-account-address-#{i}@subdomain.example.com",
        status: 0,
        priority: i
      )
    end

    visit quotas_path
    assert_selector "h1"

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

  # The desktop layout has to keep working: these same pages are read on a laptop,
  # and `flex-wrap` / stacked-on-mobile fixes are exactly the kind of change that
  # silently reflows a wide screen.
  test "fixed pages still lay out without overflow at desktop width" do
    create_session
    trigger = create_trigger
    page.driver.browser.manage.window.resize_to(1400, 900)

    [ root_path, new_session_path, settings_path, triggers_path, trigger_path(trigger),
      quotas_path, health_dashboard_path, clis_path, connectors_path,
      notifications_path ].each do |path|
      visit path
      doc_overflow, = overflow_report
      assert doc_overflow <= 0, "#{path} scrolls sideways at 1400px (#{doc_overflow}px too wide)"
    end
  end
end
