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
    helper = spawn_session(parent: worker, title: "Help out", agent_root: "agents")

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

  private

  def capture(name, element)
    FileUtils.mkdir_p(SCREENSHOT_DIR)
    scroll_into_center(element)
    page.save_screenshot(SCREENSHOT_DIR.join("proof-#{name}.png"))
  end
end
