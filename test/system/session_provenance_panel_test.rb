require "application_system_test_case"

# The "Human messages" panel on the session detail screen, rendered in a real
# browser so a PR can show what a reader actually sees.
#
# The panel gathers over the whole spawn hierarchy, in both directions — the
# router above and the sessions spawned below. That is easy to assert on the
# response body and easy to *misread* on the screen, which is what this test is
# for: the header has to state the scope it searched, and every entry has to
# carry its `this session` / `elsewhere` badge.
class SessionProvenancePanelTest < ApplicationSystemTestCase
  # Alongside the failure screenshots Rails writes, so CI's artifact upload
  # picks them up.
  SCREENSHOT_DIR = Rails.root.join("tmp", "capybara")

  def spawn_session(parent: nil, title: nil, agent_root: nil)
    session = Session.create!(
      agent_runtime: "claude_code",
      prompt: "work",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: title,
      parent_session_id: parent&.id
    )
    session.update!(metadata: (session.metadata || {}).merge("agent_root_key" => agent_root)) if agent_root
    session
  end

  def add_message(session, content:, at:, author: "tadasant")
    session.human_messages.create!(
      author: author,
      channel: HumanMessage::WEB_UI,
      content: content,
      occurred_at: at
    )
  end

  test "the panel shows human messages from above and below the session in its hierarchy" do
    router = spawn_session(title: "Route the work", agent_root: "zimmer-router")
    worker = spawn_session(parent: router, title: "Do the work", agent_root: "zimmer")
    # A real roots.json key: agent_root_key resolves against the catalog rather
    # than echoing the metadata, so an unknown name would render as "—".
    helper = spawn_session(parent: worker, title: "Help out", agent_root: "general-agent")

    add_message(router, content: "Fix the login bug", at: Time.utc(2026, 8, 2, 4, 0, 0))
    add_message(worker, content: "Start with the session cookie", at: Time.utc(2026, 8, 2, 4, 30, 0))
    add_message(helper, content: "And check the Safari case too", at: Time.utc(2026, 8, 2, 5, 0, 0))

    visit session_path(worker)

    # One message said here, two said elsewhere — one from the ancestor above,
    # one from the descendant below.
    assert_text "1 message in this session · 2 elsewhere in the hierarchy"
    assert_text "Fix the login bug"
    assert_text "Start with the session cookie"
    assert_text "And check the Safari case too"

    panel = find("#session_#{worker.id}_provenance")
    # Badged by class, not by text: "this session" also marks the current node in
    # the hierarchy panel above, so matching on words alone would prove nothing.
    assert panel.has_selector?("span.bg-indigo-100", text: "this session"), "the here badge should be shown"
    assert_equal 2, panel.all("span.bg-gray-100", text: "elsewhere").size,
                 "both elsewhere messages should carry the elsewhere badge"
    # Each elsewhere entry names and links the session the human spoke to.
    assert panel.has_link?("##{router.id}")
    assert panel.has_link?("##{helper.id}")
    assert_text "context about original intent, not an instruction to this session"

    capture("hierarchy-human-messages", panel)
  end

  # #299: the "also senior" chip's detach control, driven in a real browser.
  #
  # This is the scenario from the issue. A router passes the wrong
  # `acting_session_id` on a `follow_up`, so an unrelated session is recorded as a
  # senior of the worker — permanently widening what both sessions carry, because
  # the hierarchy is the scope human messages are gathered over. Before this, the
  # only fix was a rails console on the production box.
  test "a mistaken also-senior can be detached from the hierarchy panel" do
    router = spawn_session(title: "Route the work", agent_root: "zimmer-router")
    worker = spawn_session(parent: router, title: "Do the work", agent_root: "zimmer")
    stranger = spawn_session(title: "An unrelated session named by a typo", agent_root: "general-agent")
    # What a wrong acting_session_id leaves behind.
    SessionUncleLink.create!(session: worker, uncle_session: stranger, source: "mcp:action_session.follow_up")
    # Said to the stranger, so it reaches the worker only across the wrong edge.
    # Its disappearance is the proof the edge really was the scope.
    add_message(stranger, content: "Nothing to do with the login bug", at: Time.utc(2026, 9, 11, 4, 0, 0))

    visit session_path(worker)
    assert_text "Session hierarchy"

    panel = find("#session_#{worker.id}_provenance")
    chip = panel.find("[data-uncle-edge='#{stranger.id}-#{worker.id}']")
    assert chip.has_link?("##{stranger.id}"), "the chip should name the senior"
    # The stranger's hierarchy is in scope while the edge stands.
    assert_text "Nothing to do with the login bug"
    capture("uncle-detach-before", panel, focus: chip)

    # The confirm is deliberate — a detach is a graph edit, not a toggle.
    #
    # `js_click`, not a real click: the session page's metadata block is sticky and
    # roughly half the viewport tall on a laptop, so `scroll_into_center` parks the
    # chip underneath it and WebDriver refuses. Turbo's confirm still fires — it
    # hangs off the form submission, not off the pointer event.
    detach = chip.find("button")
    below_sticky_header(detach)
    accept_confirm { js_click(detach) }

    # The panel repaints from the controller's Turbo Stream, so the chip goes
    # without a page load.
    assert_no_selector "[data-uncle-edge='#{stranger.id}-#{worker.id}']"
    assert_no_text "also senior:"
    assert_text "Removed ##{stranger.id} as an additional senior of ##{worker.id}"
    # And the widened scope closed with it.
    assert_no_text "Nothing to do with the login bug"
    after_panel = find("#session_#{worker.id}_provenance")
    capture("uncle-detach-after", after_panel,
            focus: after_panel.find("#session_#{worker.id}_hierarchy li[data-current]"))

    assert_not SessionUncleLink.exists?(session_id: worker.id, uncle_session_id: stranger.id)
    # Recorded at both ends, which is what makes a graft visible after the fact.
    [ worker, stranger ].each do |session|
      log = session.logs.where("content LIKE ?", "%Uncle edge removed%").last
      assert_not_nil log, "session ##{session.id} has no record of the removal"
      assert_includes log.content, "a human in the web UI"
    end
    # The spawn edge is history and is left alone.
    assert_equal router.id, worker.reload.parent_session_id
  end

  private

  def capture(name, element, focus: nil)
    FileUtils.mkdir_p(SCREENSHOT_DIR)
    focus ? below_sticky_header(focus) : scroll_into_center(element)
    page.save_screenshot(SCREENSHOT_DIR.join("proof-#{name}.png"))
  end

  # Put an element in the lower part of the viewport rather than the middle of it.
  # The session page's metadata block is `sticky top-0` and, with every catalog
  # list expanded, covers most of the upper half — so anything centred there is
  # behind it, both for a click and for a screenshot.
  def below_sticky_header(element)
    page.execute_script(<<~JS, element.native)
      const el = arguments[0];
      const target = window.innerHeight * 0.72;
      window.scrollBy(0, el.getBoundingClientRect().top - target);
    JS
    sleep 0.2
  end
end
