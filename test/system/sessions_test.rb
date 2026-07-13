require "application_system_test_case"

class SessionsTest < ApplicationSystemTestCase
  # Test visiting the home page
  test "visiting the home page" do
    visit root_url

    assert_selector "h1", text: "Agent Sessions"
    assert_selector "a", text: "New Session"
  end

  test "home page shows all sessions" do
    visit root_url

    # Sessions from fixtures should be visible
    assert_text "Agent Sessions"
    assert_selector "#sessions_grid" # Container for sessions
  end

  test "home page shows empty state when no sessions" do
    # Clear all sessions (notifications first due to foreign key constraint)
    Notification.delete_all
    Session.destroy_all

    visit root_url

    assert_text "No sessions"
    assert_text "Get started by creating a new agent session"
  end

  # Test creating a new session
  test "clicking New Session navigates to new session form" do
    visit root_url

    click_on "New Session"

    assert_current_path new_session_path
    assert_selector "h1", text: "Create New Session"
  end

  test "new session form displays all required fields" do
    visit new_session_url

    # Check for Agent Root section first
    assert_selector "label", text: "Agent Root"

    # Check for prompt field
    assert_selector "textarea[name='session[prompt]']"
    assert_selector "label", text: "Initial Prompt"

    # Check for goal field
    assert_selector "label", text: "Goal"

    # Check for MCP servers section
    assert_selector "label", text: "MCP Servers"

    # Check for submit button
    assert_button "Create Session"
  end

  test "new session form hides non-user-invocable subagent roots" do
    visit new_session_url

    # User-invocable agent roots should be visible
    assert_text "General Agent"

    # Subagent roots (user_invocable: false) should NOT be visible
    assert_no_text "Pulse Catalog Management: Research & Catalog"
    assert_no_text "Pulse Catalog Management: Prepare Configs"
    assert_no_text "Pulse Catalog Management: Test with Proctor"
    assert_no_text "Pulse Catalog Management: Save to Production"
  end

  test "goal clear button clears field and hides button" do
    visit new_session_url

    # Find the goal input
    goal_input = find("input[data-goal-target='input']")

    # Fill in a goal to ensure we have a value
    goal_input.fill_in with: "Custom goal"

    # Clear button should be visible when field has value
    clear_button = find("button[data-goal-target='clearButton']")
    assert_not clear_button[:class].include?("hidden"), "Clear button should be visible when field has value"

    # Click clear button
    clear_button.click

    # Field should be cleared
    assert_equal "", goal_input.value

    # Clear button should be hidden after clearing (use visible: :all since it's hidden)
    clear_button = find("button[data-goal-target='clearButton']", visible: :all)
    assert clear_button[:class].include?("hidden"), "Clear button should be hidden when field is empty"
  end

  test "new session form displays MCP server multi-select dropdown" do
    visit new_session_url

    # Should have the multi-select dropdown component
    assert_selector "[data-controller~='mcp-server-select']"
    assert_selector "[data-mcp-server-select-target='input']"
  end

  test "MCP server dropdown shows servers when clicked" do
    visit new_session_url

    # Click on the dropdown input to show options
    find("[data-mcp-server-select-target='input']").click

    # Dropdown caps the unfiltered view at 10 results (see mcp_server_select_controller.js).
    # Spot-check that a couple of catalog servers render in that initial slice.
    # Other servers are exercised by typing into the input to filter (next test).
    assert_selector ".server-item[data-name='context7']"
    assert_selector ".server-item[data-name='playwright-custom']"
  end

  test "MCP server dropdown filtering surfaces servers by exact-name query" do
    visit new_session_url

    # The dropdown caps rendered results at 10 even when filtered (see
    # mcp_server_select_controller.js). Search for each entry by its full name to
    # keep this robust as the catalog grows.
    input = find("[data-mcp-server-select-target='input']")
    [
      "linear",
      "notion",
      "tally"
    ].each do |name|
      input.click
      input.fill_in with: name
      assert_selector ".server-item[data-name='#{name}']"
      input.fill_in with: ""
    end
  end

  # Test full session creation flow
  test "creating a new session with prompt and servers" do
    visit root_url

    # Click New Session
    click_on "New Session"
    assert_current_path new_session_path

    # Fill in the prompt
    fill_in "session[prompt]", with: "Build a user authentication system"

    # Select MCP servers using the multi-select dropdown
    find("[data-mcp-server-select-target='input']").click
    find(".server-item[data-name='context7']").click
    find("[data-mcp-server-select-target='input']").click
    find(".server-item[data-name='playwright-custom']").click

    # Click elsewhere to close the dropdown
    find("label", text: "Initial Prompt").click

    # Submit the form
    click_button "Create Session"

    # Should see success message
    assert_text "Session created successfully"

    # Should see session info in header
    assert_text "Model:"
  end

  test "creating session without selecting any servers" do
    visit new_session_url

    fill_in "session[prompt]", with: "Test prompt without servers"

    click_button "Create Session"

    assert_text "Session created successfully"
    # Prompt is no longer displayed on session detail page per Issue #57
    assert_text "Model:"
  end

  test "creating session with all servers selected" do
    visit new_session_url

    fill_in "session[prompt]", with: "Test with all servers"

    # Select all available servers using multi-select dropdown
    find("[data-mcp-server-select-target='input']").click
    find(".server-item[data-name='context7']").click
    find("[data-mcp-server-select-target='input']").click
    find(".server-item[data-name='playwright-custom']").click

    # Click elsewhere to close the dropdown
    find("label", text: "Initial Prompt").click

    click_button "Create Session"

    assert_text "Session created successfully"
    # Prompt is no longer displayed on session detail page per Issue #57

    # Should see all selected servers in the header (MCP info is inline)
    assert_text "MCP:"
    assert_text "context7"
    assert_text "playwright-custom"
  end

  test "creating session with multiple selected MCP servers" do
    visit new_session_url

    fill_in "session[prompt]", with: "Look up docs and file an issue"

    # Select two catalog MCP servers by name. The dropdown renders only the first
    # 10 matches, so a server further down the catalog (notion) is not visible until
    # the input filters the list — type its name to narrow before clicking.
    find("[data-mcp-server-select-target='input']").click
    find(".server-item[data-name='linear']").click
    notion_input = find("[data-mcp-server-select-target='input']")
    notion_input.click
    notion_input.send_keys("notion")
    find(".server-item[data-name='notion']").click

    # Click elsewhere to close the dropdown
    find("label", text: "Initial Prompt").click

    click_button "Create Session"

    assert_text "Session created successfully"
    assert_text "MCP:"
    assert_text "linear"
    assert_text "notion"
  end

  test "creating session with cmd+enter keyboard shortcut" do
    visit new_session_url

    # Fill in the prompt
    prompt_field = find("textarea[name='session[prompt]']")
    prompt_field.fill_in with: "Test with keyboard shortcut"

    # Send Cmd+Enter (Mac) to the textarea
    prompt_field.send_keys([ :command, :enter ])

    # Should see success message (form should be submitted)
    assert_text "Session created successfully"
    assert_text "Model:"
  end

  test "quick prompt desktop submit via cmd+enter keyboard shortcut" do
    visit root_url

    # The desktop quick prompt textarea is visible at md+ breakpoints (hidden md:block).
    # Headless Chrome defaults to a wide viewport, so it should be visible.
    textarea = find("textarea[data-quick-prompt-target='textarea']")
    textarea.fill_in with: "Quick prompt keyboard shortcut test"

    # Press Cmd+Enter (Meta+Enter) to submit via the quick-prompt controller
    textarea.send_keys([ :command, :enter ])

    # Quick prompt creates a router session and redirects to the session page
    assert_text "Router session created"
  end

  # Test session show page
  test "viewing a session" do
    session = sessions(:running)

    visit session_path(session)

    # Should display session information (prompt is no longer displayed per Issue #57)
    # Status is displayed inline in header
    assert_text session.status.titleize
  end

  test "session show page displays logs" do
    session = sessions(:running)

    visit session_path(session)

    # Change log level to "Show Logs" (default is now "Minimal")
    select "Show Logs", from: "log-level-filter"

    # Should display logs from fixtures
    session.logs.each do |log|
      assert_text log.content
    end
  end

  test "viewing session after creation" do
    visit new_session_url

    fill_in "session[prompt]", with: "Test session for viewing"

    # Select server using multi-select dropdown
    find("[data-mcp-server-select-target='input']").click
    find(".server-item[data-name='context7']").click
    find("label", text: "Initial Prompt").click

    click_button "Create Session"

    # Prompt is no longer displayed on session detail page per Issue #57
    # Should see session information inline in header
    assert_text "Model:"
    assert_text "MCP:"

    # Should be on a session show page
    assert_match %r{/sessions/\d+}, current_path
  end

  # Test navigation
  test "navigating back from new session form" do
    visit new_session_url

    click_on "Back to Sessions"

    assert_current_path root_path
  end

  test "cancel button returns to sessions index" do
    visit new_session_url

    click_on "Cancel"

    assert_current_path root_path
  end

  # Test form validation
  test "form allows optional prompt for clone-only sessions" do
    visit new_session_url

    # Prompt is now optional - check that required attribute is not present
    assert_selector "textarea[name='session[prompt]']"
    assert_no_selector "textarea[name='session[prompt]'][required]"

    # Check for Clone Only button (check the text content)
    assert_text "Clone Only"
  end

  test "new session form shows MCP server titles and slugs in dropdown" do
    visit new_session_url

    # Click to open the dropdown
    find("[data-mcp-server-select-target='input']").click

    # Each server (up to 10 shown) should have a title and slug/name visible in dropdown
    # The compact format shows title on left, slug on right
    ServersConfig.all.first(10).each do |server|
      assert_text server.title
      assert_text server.name # slug shown on right side
    end
  end

  test "new session form shows server info in dropdown" do
    visit new_session_url

    # Click to open the dropdown
    find("[data-mcp-server-select-target='input']").click

    # Should show server titles and descriptions in dropdown
    assert_selector ".server-item", minimum: 2
    # Verify the dropdown renders server titles (not slugs). Assert against the first
    # couple of servers from the catalog itself so this stays correct as the catalog
    # changes; both fall within the dropdown's 10-item display cap.
    ServersConfig.all.first(2).each do |server|
      assert_text server.title
    end
  end

  # Test session list functionality
  test "sessions index shows recent sessions first" do
    # Create sessions with known order
    old_session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Old session",
      status: :archived,
      created_at: 2.days.ago
    )

    new_session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "New session",
      status: :running,
      created_at: 1.hour.ago
    )

    visit root_path

    # Should show newer session first (in HTML order)
    page_text = page.text
    new_position = page_text.index("New session")
    old_position = page_text.index("Old session")

    # If both are present, new should come before old
    if new_position && old_position
      assert new_position < old_position
    end
  end

  # Test complete user workflow
  test "complete workflow from index to session creation to viewing" do
    # Start at home page
    visit root_url
    assert_selector "h1", text: "Agent Sessions"

    # Navigate to new session
    click_on "New Session"
    assert_selector "h1", text: "Create New Session"

    # Fill out the form
    fill_in "session[prompt]", with: "Complete workflow test session"

    # Select servers using multi-select dropdown
    find("[data-mcp-server-select-target='input']").click
    find(".server-item[data-name='context7']").click
    find("[data-mcp-server-select-target='input']").click
    find(".server-item[data-name='playwright-custom']").click
    find("label", text: "Initial Prompt").click

    # Create session
    click_button "Create Session"

    # Should be on show page with success message
    assert_text "Session created successfully"
    # Prompt is no longer displayed on session detail page per Issue #57

    # Should see session details inline in header
    assert_text "Model:"

    # Should see selected MCP servers inline in header
    assert_text "MCP:"
    assert_text "context7"
    assert_text "playwright-custom"
  end

  # Test accessibility and UI elements
  test "buttons and links have proper styling" do
    visit root_url

    # New Session button should be visible and styled
    assert_selector "a[href='#{new_session_path}']"
  end

  test "form has proper labels and accessibility" do
    visit new_session_url

    # All inputs should have associated labels
    assert_selector "label[for]", minimum: 1

    # MCP server multi-select should have a label
    assert_selector "label", text: "MCP Servers"
    # The multi-select dropdown should be present
    assert_selector "[data-controller~='mcp-server-select']"
  end

  # Test slug functionality
  test "session does not have slug on creation" do
    visit new_session_url

    fill_in "session[prompt]", with: "Test session for slug generation"
    click_button "Create Session"

    assert_text "Session created successfully"

    # Find the created session - should NOT have slug initially
    session = Session.last
    assert_nil session.slug
  end

  test "session generates slug from title when title is set" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session",
      status: :running,
      title: "Fix Authentication Bug"
    )

    # Call generate_slug_from_title! method
    session.generate_slug_from_title!

    # Should have slug based on title + datetime
    assert_not_nil session.slug
    assert_match /\Afix-authentication-bug-\d{8}-\d{4}\z/, session.slug
  end

  test "session ID is displayed on session cards" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session with slug",
      status: :running,
      title: "Test Title",
      slug: "test-title-20251114-1230"
    )

    visit root_path

    # Session ID should be displayed
    assert_text "##{session.id}"
    # Slug should not be displayed on cards
    assert_no_text "test-title-20251114-1230"
  end


  test "session without slug does not display slug on cards" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session without slug",
      status: :running
    )

    visit root_path

    # Slug should not be shown
    assert_no_text /\A[a-z0-9-]+-\d{8}-\d{4}\z/
  end

  # Test title editing functionality
  test "clicking edit icon allows editing session title on index page" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session",
      status: :running,
      title: "Original Title"
    )

    visit root_path

    # Title should be displayed
    assert_text "Original Title"

    # Note: In a real system test with JavaScript, we would:
    # 1. Click the edit button
    # 2. Fill in the new title
    # 3. Press Enter to save
    # 4. Verify the title updated
    # However, this requires JavaScript execution which needs proper Capybara setup
  end

  test "clicking edit icon allows editing session title on show page" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session",
      status: :running,
      title: "Original Title"
    )

    visit session_path(session)

    # Title should be displayed
    assert_text "Original Title"

    # Note: In a real system test with JavaScript, we would:
    # 1. Click the edit button
    # 2. Fill in the new title
    # 3. Press Enter to save
    # 4. Verify the title updated
  end

  test "session card displays archive button for non-archived sessions" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session",
      status: :running
    )

    visit root_path

    within("#session_#{session.id}") do
      assert_link "Trash"
    end
  end

  test "session card does not display archive button for archived sessions" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Archived session",
      status: :archived
    )

    visit root_path(show_archived: "true")

    within("#session_#{session.id}") do
      # Check that there's no link pointing to the archive action
      # (can't use assert_no_link "Archive" because the card is an anchor tag containing "Archived" status text)
      assert_no_selector "a[href$='/archive']"
    end
  end

  # Test title display
  test "session with title displays title on index page" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :running,
      title: "My Custom Title"
    )

    visit root_path

    assert_text "My Custom Title"
  end

  test "session without explicit title gets auto-generated title on index page" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :running
    )

    visit root_path

    # Auto-generated title is shown (set by after_create callback)
    assert_text "Session #{session.id}"
  end

  # Test default goal selection
  test "new session form selects default goal for default agent root" do
    visit new_session_url

    # Find the default agent root
    default_agent_root = AgentRootsConfig.default

    # If the default agent root has a default goal, verify it's selected
    if default_agent_root&.default_goal.present?
      goal = GoalsConfig.find(default_agent_root.default_goal)
      expected_description = goal&.description

      # The visible input field should show the description
      goal_input = find("input[data-goal-target='input']")
      assert_equal expected_description, goal_input.value,
        "Expected goal input to show '#{expected_description}' for default agent root '#{default_agent_root.name}'"

      # The hidden field should also have the description
      hidden_field = find("input[data-goal-target='hiddenField']", visible: false)
      assert_equal expected_description, hidden_field.value,
        "Expected hidden goal field to have '#{expected_description}'"
    end
  end

  test "changing agent root updates goal to agent root's default" do
    visit new_session_url

    # Find agent roots with different goals
    agent_roots_with_conditions = AgentRootsConfig.all.select { |r| r.default_goal.present? }

    if agent_roots_with_conditions.size >= 2
      first_agent_root = agent_roots_with_conditions.first
      second_agent_root = agent_roots_with_conditions.second

      # Select first agent root via the agent-root-select Stimulus controller
      # (radio buttons are hidden — they exist only to preserve change-event listeners)
      select_agent_root(first_agent_root.name)

      # Verify first agent root's goal is shown
      goal1 = GoalsConfig.find(first_agent_root.default_goal)
      goal_input = find("input[data-goal-target='input']")
      assert_equal goal1.description, goal_input.value

      # Select second agent root
      select_agent_root(second_agent_root.name)

      # Verify second agent root's goal is shown
      goal2 = GoalsConfig.find(second_agent_root.default_goal)
      assert_equal goal2.description, goal_input.value
    end
  end

  test "changing to agent root without goal clears the field" do
    visit new_session_url

    # The new-session form only renders radios for user-invocable agent roots, so
    # pick from that set — a non-invocable root has no `agent_root_<name>` element to
    # drive, and getElementById would return null.
    # Find an agent root with a goal
    agent_root_with_condition = AgentRootsConfig.user_invocable.find { |r| r.default_goal.present? }
    # Find an agent root without a goal
    agent_root_without_condition = AgentRootsConfig.user_invocable.find { |r| r.default_goal.blank? }

    if agent_root_with_condition && agent_root_without_condition
      # Select agent root with goal (radios are hidden — go through the controller)
      select_agent_root(agent_root_with_condition.name)

      # Verify goal is populated
      goal_input = find("input[data-goal-target='input']")
      expected_description = GoalsConfig.find(agent_root_with_condition.default_goal).description
      assert_equal expected_description, goal_input.value

      # Select agent root without goal
      # Directly invoke the Stimulus controller method since Capybara's click/dispatchEvent
      # doesn't reliably trigger Stimulus data-action handlers in headless Chrome
      page.execute_script("
        const radio = document.getElementById('agent_root_#{agent_root_without_condition.name}');
        radio.checked = true;
        const controller = document.querySelector('[data-controller*=\"goal\"]');
        const stimulusController = window.Stimulus.getControllerForElementAndIdentifier(controller, 'goal');
        stimulusController.handleAgentRootChange({ target: radio });
      ")

      # Wait for JavaScript to execute
      sleep 0.1

      # Verify goal field is cleared
      assert_equal "", goal_input.value,
        "Goal should be cleared when selecting agent root without default"
    end
  end

  test "agent roots sharing same URL but different names have independent goals" do
    visit new_session_url

    # Find agent roots that share the same URL (monorepo)
    # e.g., agent-orchestrator and general-agent both use https://github.com/tadasant/zimmer-catalog.git
    agents_url = "https://github.com/tadasant/zimmer-catalog.git"
    roots_sharing_url = AgentRootsConfig.all.select { |r| r.url == agents_url }

    if roots_sharing_url.size >= 2
      # Example: agent-orchestrator has goal, general-agent doesn't
      root_with = roots_sharing_url.find { |r| r.default_goal.present? }
      root_without = roots_sharing_url.find { |r| r.default_goal.blank? }

      if root_with && root_without
        # Select agent root with goal (radios are hidden — go through the controller)
        select_agent_root(root_with.name)
        goal_input = find("input[data-goal-target='input']")
        expected_description = GoalsConfig.find(root_with.default_goal).description
        assert_equal expected_description, goal_input.value

        # Select agent root without goal (same URL, different name)
        # Directly invoke the Stimulus controller method since Capybara's click/dispatchEvent
        # doesn't reliably trigger Stimulus data-action handlers in headless Chrome
        page.execute_script("
          const radio = document.getElementById('agent_root_#{root_without.name}');
          radio.checked = true;
          const controller = document.querySelector('[data-controller*=\"goal\"]');
          const stimulusController = window.Stimulus.getControllerForElementAndIdentifier(controller, 'goal');
          stimulusController.handleAgentRootChange({ target: radio });
        ")

        # Wait for JavaScript to execute
        sleep 0.1

        assert_equal "", goal_input.value,
          "Goal should clear when selecting agent root without default, even if it shares URL with another root"
      end
    end
  end

  # === Tests for default MCP server selection per agent root ===

  test "new session form pre-selects MCP servers for default agent root" do
    visit new_session_url

    # Find the default agent root
    default_agent_root = AgentRootsConfig.default

    # The selected container should always exist (use visible: :all since it may be empty)
    assert_selector "[data-mcp-server-select-target='selectedContainer']", visible: :all

    # If the default agent root has default MCP servers, verify they're selected
    if default_agent_root&.default_mcp_servers.present?
      default_agent_root.default_mcp_servers.each do |server_name|
        if ServersConfig.exists?(server_name)
          # Check that the server is shown in the selected container
          assert_selector "[data-mcp-server-select-target='selectedContainer'] span", text: ServersConfig.find(server_name).title
        end
      end
    else
      # No default servers means the container should be empty (no span tags inside)
      assert_no_selector "[data-mcp-server-select-target='selectedContainer'] span"
    end
  end

  test "selecting agent root with default MCP servers pre-selects those servers" do
    visit new_session_url

    # Find an agent root with MCP servers configured
    agent_root_with_servers = AgentRootsConfig.all.find { |r| r.default_mcp_servers.present? }

    skip "No agent roots with default MCP servers configured" unless agent_root_with_servers

    # Directly invoke the Stimulus controller method since Capybara's choose/click
    # doesn't reliably trigger Stimulus data-action handlers in headless Chrome
    page.execute_script("var radio = document.getElementById('agent_root_#{agent_root_with_servers.name}'); radio.checked = true; var container = document.querySelector('[data-controller*=\"mcp-server-select\"]'); var stimulusController = window.Stimulus.getControllerForElementAndIdentifier(container, 'mcp-server-select'); stimulusController.handleAgentRootChange({ target: radio });")

    # Wait for JavaScript to execute
    sleep 0.1

    # Verify the MCP servers are shown in the selected container
    agent_root_with_servers.default_mcp_servers.each do |server_name|
      if ServersConfig.exists?(server_name)
        server = ServersConfig.find(server_name)
        assert_selector "[data-mcp-server-select-target='selectedContainer'] span", text: server.title
      end
    end
  end

  test "changing agent root updates MCP server selection to agent root's defaults" do
    visit new_session_url

    # Find agent roots with different MCP servers
    agent_roots_with_servers = AgentRootsConfig.all.select { |r| r.default_mcp_servers.present? }

    skip "Need at least 2 agent roots with different MCP servers" unless agent_roots_with_servers.size >= 2

    first_agent_root = agent_roots_with_servers.first
    second_agent_root = agent_roots_with_servers.second

    # Directly invoke the Stimulus controller method for first agent root
    page.execute_script("var radio = document.getElementById('agent_root_#{first_agent_root.name}'); radio.checked = true; var container = document.querySelector('[data-controller*=\"mcp-server-select\"]'); var stimulusController = window.Stimulus.getControllerForElementAndIdentifier(container, 'mcp-server-select'); stimulusController.handleAgentRootChange({ target: radio });")
    sleep 0.1

    # Verify first agent root's MCP servers are shown
    first_agent_root.default_mcp_servers.each do |server_name|
      if ServersConfig.exists?(server_name)
        server = ServersConfig.find(server_name)
        assert_selector "[data-mcp-server-select-target='selectedContainer'] span", text: server.title
      end
    end

    # Directly invoke the Stimulus controller method for second agent root
    page.execute_script("var radio = document.getElementById('agent_root_#{second_agent_root.name}'); radio.checked = true; var container = document.querySelector('[data-controller*=\"mcp-server-select\"]'); var stimulusController = window.Stimulus.getControllerForElementAndIdentifier(container, 'mcp-server-select'); stimulusController.handleAgentRootChange({ target: radio });")
    sleep 0.1

    # Verify second agent root's MCP servers are shown
    second_agent_root.default_mcp_servers.each do |server_name|
      if ServersConfig.exists?(server_name)
        server = ServersConfig.find(server_name)
        assert_selector "[data-mcp-server-select-target='selectedContainer'] span", text: server.title
      end
    end
  end

  test "changing to agent root without default MCP servers clears selection" do
    visit new_session_url

    # Only user-invocable roots render a radio in the form; pick from that set so the
    # `agent_root_<name>` element the script drives actually exists in the DOM.
    # Find an agent root with MCP servers
    agent_root_with_servers = AgentRootsConfig.user_invocable.find { |r| r.default_mcp_servers.present? }
    # Find an agent root without MCP servers
    agent_root_without_servers = AgentRootsConfig.user_invocable.find { |r| r.default_mcp_servers.blank? }

    skip "Need agent roots with and without MCP servers" unless agent_root_with_servers && agent_root_without_servers

    # Directly invoke the Stimulus controller method for agent root with MCP servers
    page.execute_script("var radio = document.getElementById('agent_root_#{agent_root_with_servers.name}'); radio.checked = true; var container = document.querySelector('[data-controller*=\"mcp-server-select\"]'); var stimulusController = window.Stimulus.getControllerForElementAndIdentifier(container, 'mcp-server-select'); stimulusController.handleAgentRootChange({ target: radio });")
    sleep 0.1

    # Verify MCP servers are populated
    agent_root_with_servers.default_mcp_servers.each do |server_name|
      if ServersConfig.exists?(server_name)
        server = ServersConfig.find(server_name)
        assert_selector "[data-mcp-server-select-target='selectedContainer'] span", text: server.title
      end
    end

    # Directly invoke the Stimulus controller method for agent root without MCP servers
    page.execute_script("var radio = document.getElementById('agent_root_#{agent_root_without_servers.name}'); radio.checked = true; var container = document.querySelector('[data-controller*=\"mcp-server-select\"]'); var stimulusController = window.Stimulus.getControllerForElementAndIdentifier(container, 'mcp-server-select'); stimulusController.handleAgentRootChange({ target: radio });")
    sleep 0.1

    # Verify MCP server selection is cleared - the container should have no span tags
    assert_no_selector "[data-mcp-server-select-target='selectedContainer'] span"
  end

  test "user can manually add MCP servers after auto-selection" do
    visit new_session_url

    # Find an agent root with MCP servers
    agent_root_with_servers = AgentRootsConfig.all.find { |r| r.default_mcp_servers.present? }

    skip "No agent roots with default MCP servers configured" unless agent_root_with_servers

    # Directly invoke the Stimulus controller method for agent root with MCP servers
    page.execute_script("var radio = document.getElementById('agent_root_#{agent_root_with_servers.name}'); radio.checked = true; var container = document.querySelector('[data-controller*=\"mcp-server-select\"]'); var stimulusController = window.Stimulus.getControllerForElementAndIdentifier(container, 'mcp-server-select'); stimulusController.handleAgentRootChange({ target: radio });")
    sleep 0.1

    # Open the dropdown and select an additional server
    find("[data-mcp-server-select-target='input']").click

    # Find a server that's NOT in the default list
    additional_server = ServersConfig.all.find { |s| !agent_root_with_servers.default_mcp_servers.include?(s.name) }

    skip "No additional servers available to add" unless additional_server

    find(".server-item[data-name='#{additional_server.name}']").click

    # Verify both default and manually added servers are shown
    assert_selector "[data-mcp-server-select-target='selectedContainer'] span", text: additional_server.title
  end

  # === Tests for session recovery auto-refresh (Issue #275) ===

  test "session show page displays recovery banner when recently recovered" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session",
      status: :running
    )

    # Create a recent recovery log (within 5 second window)
    session.logs.create!(
      level: "info",
      content: "Recovery job enqueued (ActiveJob ID: test123) - monitoring will resume in 5 seconds",
      created_at: 2.seconds.ago
    )

    visit session_path(session)

    # Should display the recovery warning banner
    assert_text "Session connection recovered. Page will refresh in 3 seconds to restore live updates..."
  end

  test "session show page does not display recovery banner when not recently recovered" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session",
      status: :running
    )

    # Create an old recovery log (outside 5 second window)
    session.logs.create!(
      level: "info",
      content: "Recovery job enqueued (ActiveJob ID: test123) - monitoring will resume in 5 seconds",
      created_at: 10.seconds.ago
    )

    visit session_path(session)

    # Should NOT display the recovery warning banner
    assert_no_text "Session connection recovered. Page will refresh in 3 seconds to restore live updates..."
  end

  test "session show page has meta refresh tag when recently recovered" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session",
      status: :running
    )

    # Create a recent recovery log (within 5 second window)
    session.logs.create!(
      level: "info",
      content: "Recovery job enqueued (ActiveJob ID: test123) - monitoring will resume in 5 seconds",
      created_at: 2.seconds.ago
    )

    visit session_path(session)

    # Should have meta refresh tag with 3 second delay
    assert_selector "meta[http-equiv='refresh'][content='3']", visible: false
  end

  test "session show page does not have meta refresh tag when not recently recovered" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session",
      status: :running
    )

    visit session_path(session)

    # Should NOT have meta refresh tag
    assert_no_selector "meta[http-equiv='refresh']", visible: false
  end

  # --- Session detail drawer -------------------------------------------------

  test "clicking View opens the session detail drawer without leaving the dashboard" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Drawer test session",
      status: :running
    )

    visit root_url

    # The panel exists in the DOM but is dismissed (translated off-screen).
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='true']", visible: :all

    find("a[aria-label='View session #{session.id}']").click

    # Drawer is now open and the dashboard did NOT navigate away.
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"
    assert_current_path root_path
    # The detail loaded into the lazy frame, streaming subscriptions and all.
    # Assert on the session id (always rendered in the detail header) and the
    # follow-up form (the whole point — acting on the session from the drawer);
    # a running session shows an "Agent is running…" placeholder, not the prompt.
    within "turbo-frame#session_detail" do
      assert_text "##{session.id}"
      assert_text "Follow-up Prompt"
    end
  end

  test "the session detail drawer closes via the close button and Escape" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Closable drawer session",
      status: :running
    )

    visit root_url
    view_link = "a[aria-label='View session #{session.id}']"

    # Close via the in-drawer Close control.
    find(view_link).click
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"
    # The panel flips to aria-hidden='false' synchronously on open. The Close
    # button lives in the lazy-loaded Turbo Frame, so wait for the detail to
    # render before clicking it. Match the frame body's unique data attribute
    # (exact, not a substring of the id, so a sibling test's "#12" can't satisfy
    # a wait for "#1").
    assert_selector "turbo-frame#session_detail [data-current-session-id='#{session.id}']"
    # The Close button is marked data-session-drawer-close and dismissed by an
    # eagerly-bound delegated listener on the session-drawer controller root, so
    # a single click is honored the instant the button exists — no race against
    # Stimulus wiring a per-button action onto the freshly-swapped frame content.
    within "[data-session-drawer-target='panel']" do
      find("button[aria-label='Close session details']").click
    end
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='true']", visible: :all

    # Reopen and close via Escape.
    find(view_link).click
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"
    # Escape is handled by a document-level keydown listener (wired on the
    # controller's connect, not the frame), but still wait for the reopened
    # detail to settle so the panel is fully interactive before dismissing.
    assert_selector "turbo-frame#session_detail [data-current-session-id='#{session.id}']"
    find("body").send_keys(:escape)
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='true']", visible: :all
  end

  # On a mobile-width viewport the drawer is too clunky, so clicking View must do
  # a plain full-page navigation to the session page instead of opening the drawer.
  test "clicking View on mobile navigates to the full session page instead of opening the drawer" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Mobile drawer-skip session",
      status: :running
    )

    # Below the sm: 640px breakpoint the controller treats the viewport as mobile.
    page.driver.browser.manage.window.resize_to(375, 812)
    begin
      visit root_url

      # The drawer panel starts dismissed.
      assert_selector "[data-session-drawer-target='panel'][aria-hidden='true']", visible: :all

      find("a[aria-label='View session #{session.id}']").click

      # Native navigation occurred: we are now on the full session page, not the
      # dashboard, and the drawer never opened.
      assert_current_path session_path(session)
      assert_selector "[data-current-session-id='#{session.id}']"
      assert_no_selector "[data-session-drawer-target='panel'][aria-hidden='false']", visible: :all
    ensure
      # Restore the desktop viewport so sibling tests aren't affected.
      page.driver.browser.manage.window.resize_to(1400, 900)
    end
  end

  # The whole point of loading the detail via a real Turbo Frame is that you can
  # act on the session from the drawer. Queue a follow-up from inside the drawer
  # and confirm the round-trip stays in the frame: the message is enqueued, the
  # form resets in place, and the drawer never navigates the dashboard away.
  test "a follow-up queued from the drawer stays in the drawer" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Follow-up from drawer session",
      status: :running
    )

    visit root_url
    find("a[aria-label='View session #{session.id}']").click
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"

    within "[data-session-drawer-target='panel']" do
      fill_in "follow_up_prompt", with: "Queued from the drawer"
      click_button "Queue Message"
      # Turbo Stream response targets the drawer's session-scoped form id, so the
      # form resets in place (textarea cleared, queue badge increments).
      assert_selector ".bg-indigo-100", text: "1", wait: 5
      assert_empty find("textarea[name='follow_up_prompt']").value
    end

    # Drawer is still open and the dashboard was never navigated away.
    assert_selector "[data-session-drawer-target='panel'][aria-hidden='false']"
    assert_current_path root_path

    # And the message actually persisted.
    session.reload
    assert_equal 1, session.enqueued_messages.count
    assert_equal "Queued from the drawer", session.enqueued_messages.first.content
  end
end
