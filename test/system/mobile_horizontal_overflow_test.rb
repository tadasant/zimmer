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

  # The spot gate's genesis rows are the screen this suite exists for: the table's
  # Action column is the only control there, and it does not fit a phone, so below
  # `sm` the rows render as stacked cards with the button on screen.
  test "spot gate genesis controls are reachable on a phone" do
    visit settings_path
    assert_text "Genesis classes"

    kind = SessionGenesis::KINDS.first
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

  test "triggers index and detail do not overflow horizontally on a phone" do
    trigger = create_trigger

    visit triggers_path
    assert_text trigger.name
    assert_no_horizontal_overflow("triggers index")

    visit trigger_path(trigger)
    assert_text "Run Now"
    assert_no_horizontal_overflow("trigger detail")
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
