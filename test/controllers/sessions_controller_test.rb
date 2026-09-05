require "test_helper"
require "mocha/minitest"
require "automated_prompts"
require "ostruct"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  include AttachmentFixtures

  def setup
    # Stub Turbo Stream broadcasting to avoid missing partial errors in tests
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
  end

  def teardown
    # Clean up all stubs to prevent leakage between tests
    Mocha::Mockery.instance.teardown
    # Durable attachment storage outlives the test that wrote it.
    cleanup_stored_attachments!
  end

  # Test index action
  test "should get index" do
    get root_url
    assert_response :success
    # Page should contain expected content
    assert_select "h1", text: "Agent Sessions"
  end

  test "should list sessions in descending order" do
    # Create test sessions with known order
    old_session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Old", created_at: 1.day.ago)
    new_session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "New", created_at: 1.hour.ago)

    get root_url
    assert_response :success

    # Verify page renders successfully
    assert_select "body"
  end

  test "should display all sessions on index" do
    get root_url
    assert_response :success

    # Check that fixture sessions are present
    assert_select "body" # Basic check that page renders
  end

  # Test pagination — the Uncategorized bucket paginates independently via the
  # "uncategorized" sentinel page key (page[uncategorized]=N).
  test "should paginate sessions with 50 per page" do
    # Clean up to ensure we have control over session count
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    # Create enough sessions to require pagination
    55.times { |i| Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test session #{i}") }

    get root_url(every_status_params)
    assert_response :success

    # Should show 50 session cards on the page (one for each session)
    assert_select "#sessions_grid turbo-frame", count: 50
  end

  test "should navigate to second page" do
    # Clean up first
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    # Create enough sessions for pagination
    60.times { |i| Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test session #{i}") }

    # Uncategorized's page key is the "uncategorized" sentinel, not a global ?page=.
    get root_url(every_status_params(page: { uncategorized: 2 }))
    assert_response :success

    # Should show remaining 10 sessions on second page
    assert_select "#sessions_grid turbo-frame", count: 10
  end

  # Malformed or legacy page params must not 500. A scalar (?page=2) or array
  # (?page[]=2) is not a keyed hash, so every section falls back to page 1 rather
  # than raising when indexed with a string key.
  test "non-hash page params fall back to page 1 without raising" do
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    60.times { |i| Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test session #{i}") }

    # Legacy scalar bookmark: ignored, Uncategorized renders its first 50.
    get root_url(every_status_params(page: "2"))
    assert_response :success
    assert_select "#sessions_grid turbo-frame", count: 50

    # Malformed array param must not raise a TypeError.
    get root_url(every_status_params("page[]" => "2"))
    assert_response :success
    assert_select "#sessions_grid turbo-frame", count: 50
  end

  test "paginating one category does not disturb another" do
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    cat_a = Category.create!(name: "Alpha")
    cat_b = Category.create!(name: "Beta")

    # Each category gets more than one page worth of sessions.
    60.times { |i| Session.create!(git_root: "https://github.com/test/repo.git", prompt: "A#{i}", category: cat_a) }
    60.times { |i| Session.create!(git_root: "https://github.com/test/repo.git", prompt: "B#{i}", category: cat_b) }

    # Advance only category A to page 2; category B's key is absent, so it stays page 1.
    get root_url(every_status_params(page: { cat_a.id.to_s => 2 }))
    assert_response :success

    # Category A's frame shows its remaining 10 cards (page 2 of 60).
    assert_select "##{ActionView::RecordIdentifier.dom_id(cat_a)} turbo-frame.category-collapse-body turbo-frame", count: 10
    # Category B is untouched: still its first 50 cards.
    assert_select "##{ActionView::RecordIdentifier.dom_id(cat_b)} turbo-frame.category-collapse-body turbo-frame", count: 50

    # Each header's count badge shows the section's unpaginated total (60), not the
    # current page size — so a collapsed section still reports how many are inside.
    assert_select "[data-category-count-id='#{cat_a.id}']", text: "60"
    assert_select "[data-category-count-id='#{cat_b.id}']", text: "60"
  end

  test "each category section renders its own collapse toggle and pagination frame" do
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    category = Category.create!(name: "Gamma")
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "G", category: category)

    get root_url(every_status_params)
    assert_response :success

    # Both the Uncategorized bucket and the real category are collapsible.
    assert_select "section[data-controller='category-collapse'][data-category-collapse-key-value='uncategorized']"
    assert_select "section[data-controller='category-collapse'][data-category-collapse-key-value='#{category.id}']"
    # Each section's body is wrapped in its own per-category turbo-frame.
    assert_select "turbo-frame#category_frame_uncategorized.category-collapse-body"
    assert_select "turbo-frame#category_frame_#{category.id}.category-collapse-body"
    # Each header carries a session-count badge (visible even when collapsed).
    assert_select "[data-category-count-id='uncategorized']"
    assert_select "[data-category-count-id='#{category.id}']", text: "1"
  end

  # Test search functionality
  test "should search sessions by title" do
    # Clean up first
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    # Create sessions with specific titles
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "First session", title: "Alpha Report")
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Second session", title: "Beta Analysis")
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Third session", title: "Alpha Summary")

    get root_url(every_status_params(q: "Alpha"))
    assert_response :success

    # Should find sessions with "Alpha" in title
    assert_select "#sessions_grid turbo-frame", count: 2
  end

  test "should search sessions by metadata" do
    # Clean up first
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    session1 = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Session with metadata")
    session1.update!(metadata: { "project" => "test-project" })

    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Another session")

    get root_url(every_status_params(q: "test-project"))
    assert_response :success

    # Should find session with matching metadata
    assert_select "#sessions_grid turbo-frame", count: 1
  end

  test "should search transcript content when search_contents is enabled" do
    # Clean up first
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    session1 = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Session one")
    session1.update!(transcript: '{"role":"user","content":"find this unique content"}')

    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Session two")

    # Without search_contents, should not find by transcript
    get root_url(every_status_params(q: "unique content", search_contents: "0"))
    assert_response :success
    assert_match /No sessions found/, response.body

    # With search_contents, should find by transcript
    get root_url(every_status_params(q: "unique content", search_contents: "1"))
    assert_response :success
    assert_select "#sessions_grid turbo-frame", count: 1
    # A bounded scan owes the reader the difference between "no matches" and
    # "I stopped looking" — see SessionContentSearch.
    assert_match(/Transcript scan complete/, response.body)

    # The REST API's spelling works here too, so a URL copied either way behaves the same.
    get root_url(every_status_params(q: "unique content", search_contents: "true"))
    assert_response :success
    assert_select "#sessions_grid turbo-frame", count: 1
  end

  test "the content scan runs after the agent-root and genesis filters, not before" do
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    match = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "In scope",
      genesis: "web_ui")
    match.update!(transcript: '{"role":"user","content":"find this unique content"}')
    # Same phrase, different genesis: it must not be a candidate at all, so the scan
    # never spends its budget reading it and the notice's count never counts it.
    other = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Out of scope",
      genesis: "api")
    other.update!(transcript: '{"role":"user","content":"find this unique content"}')

    get root_url(every_status_params(q: "unique content", search_contents: "1", genesis: "web_ui"))
    assert_response :success

    assert_select "#sessions_grid turbo-frame", count: 1
    assert_match(/the one session\s+matching these filters was searched/, response.body)
  end

  test "a title-only search shows no transcript-scan notice" do
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Session one", title: "Findable")

    get root_url(every_status_params(q: "Findable"))
    assert_response :success
    assert_no_match(/Transcript scan/, response.body)
  end

  test "should combine search with the status filter" do
    # Clean up first
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Active session", title: "Active Test")
    archived_session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Archived session", title: "Archived Test")
    archived_session.update!(status: :archived)

    # Ticking nothing means every status, so a search spans both.
    get root_url(every_status_params(q: "Test"))
    assert_response :success
    assert_select "#sessions_grid turbo-frame", count: 2

    # Naming one status narrows the same search to it.
    get root_url(every_status_params(q: "Test", status: [ "waiting" ]))
    assert_response :success
    assert_select "#sessions_grid turbo-frame", count: 1

    # And naming archived is how the trash is searched.
    get root_url(every_status_params(q: "Test", status: [ "archived" ]))
    assert_response :success
    assert_select "#sessions_grid turbo-frame", count: 1
  end

  test "should display search query in form" do
    get root_url(q: "my search")
    assert_response :success
    assert_select "input[name='q'][value='my search']"
  end

  test "should show empty state when no search results" do
    get root_url(q: "nonexistent12345")
    assert_response :success
    assert_match /No sessions found/, response.body
  end

  # Test new action
  test "should get new" do
    get new_session_url
    assert_response :success
    assert_select "h1", text: "Create New Session"
  end

  test "should display new session form" do
    get new_session_url
    assert_response :success

    # Check for form elements
    assert_select "textarea[name='session[prompt]']"
    assert_select "input[type='submit']"
  end

  # The config facades rescue CatalogError to [], so a broken catalog renders the
  # form with empty pickers and no explanation. These three cover the banner that
  # tells the two states apart.
  test "new session form shows no catalog banner when the catalog resolves" do
    AirCatalogService.stubs(:resolve_failure).returns(nil)

    get new_session_url
    assert_response :success
    assert_select "[role=alert]", text: /Catalog resolution failed/, count: 0
  end

  test "new session form warns that empty pickers are a catalog failure" do
    AirCatalogService.stubs(:resolve_failure).returns({ message: "air resolve failed (exit 1): boom", at: Time.current })
    AirCatalogService.stubs(:degraded?).returns(false)

    get new_session_url
    assert_response :success
    assert_match(/Catalog resolution failed — the lists below are empty/, response.body)
    assert_match(/air resolve failed \(exit 1\): boom/, response.body)
  end

  test "new session form warns that pickers are stale when a last-known-good catalog is served" do
    AirCatalogService.stubs(:resolve_failure).returns({ message: "air resolve failed (exit 1): boom", at: Time.current })
    AirCatalogService.stubs(:degraded?).returns(true)
    AirCatalogService.stubs(:last_known_good_at).returns(2.hours.ago)

    get new_session_url
    assert_response :success
    assert_match(/Catalog resolution failed — showing the last catalog that worked/, response.body)
    assert_match(/2 hours ago/, response.body)
  end

  # --- the picker's availability flag ----------------------------------------
  #
  # #538: the form offered every catalog server identically, including ones
  # Zimmer already knew could not start. Picking one of those is not a soft
  # failure — an unresolved `${VAR}` raises SecretsInterpolator::MissingVariableError
  # at prepare time and fails the whole session, not just that server. The
  # picker's payload now carries the same signal get_configs partitions on.

  # The Stimulus value is JSON in a data attribute; parse it rather than regexing
  # the escaped HTML, so the assertion is about the payload and not its encoding.
  def picker_servers
    value = css_select("[data-mcp-server-select-servers-value]").first["data-mcp-server-select-servers-value"]
    JSON.parse(value)
  end

  test "the new session form's picker payload carries each server's availability" do
    with_mixed_availability_catalog { get new_session_url }
    assert_response :success

    servers = picker_servers

    healthy = servers.find { |s| s["name"] == "context7" }
    assert_equal false, healthy["unavailable"]
    assert_nil healthy["unavailable_reason"]

    unseeded = servers.find { |s| s["name"] == "strad-secrets-staging-rw" }
    assert_equal true, unseeded["unavailable"]
    assert_equal "STRAD_STAGING_API_KEY unresolved", unseeded["unavailable_reason"]

    declared = servers.find { |s| s["name"] == "strad-secrets-oauth" }
    assert_equal true, declared["unavailable"]
    assert_equal "The endpoint accepts only static bearer tokens and exposes no OAuth discovery.",
      declared["unavailable_reason"]
  end

  # Shown and flagged, not hidden. A human can usually fix why a server is
  # unavailable — "OAuth authorization not completed" is one click away at
  # /connectors — which is exactly what an agent reading get_configs cannot do,
  # so where that surface omits the entry this one keeps it and says why.
  test "the new session form still offers every catalog server" do
    with_mixed_availability_catalog { get new_session_url }
    assert_response :success

    assert_equal %w[context7 zimmer-self-session strad-secrets-staging-rw strad-secrets-oauth],
      picker_servers.map { |s| s["name"] }
  end

  test "the picker's reason is plain text, not the markdown get_configs renders" do
    with_mixed_availability_catalog { get new_session_url }
    assert_response :success

    reason = picker_servers.find { |s| s["name"] == "strad-secrets-staging-rw" }["unavailable_reason"]
    refute_includes reason, "`", "a backtick renders as a backtick in a dropdown row"
  end

  # A store outage hits every server at once, so flagging on an indeterminate
  # answer would paint the whole picker amber for a blip that fixes itself.
  test "the picker does not flag a server whose secret store could not be reached" do
    outage = SecretsInterpolator::Resolution.new(
      state: :unavailable, error: StandardError.new("Parameter Store timed out")
    )
    with_mixed_availability_catalog(resolution: outage) { get new_session_url }
    assert_response :success

    assert_equal false, picker_servers.find { |s| s["name"] == "strad-secrets-staging-rw" }["unavailable"]
  end

  # The form must render even if readiness cannot be computed at all: a picker
  # with no flags beats a form that offers nothing.
  test "the new session form renders its picker when the readiness computation fails" do
    ConnectorStatusProbe.stubs(:all).raises(StandardError, "probe exploded")

    with_mixed_availability_catalog { get new_session_url }
    assert_response :success

    servers = picker_servers
    assert_equal 4, servers.size
    assert servers.none? { |s| s["unavailable"] }
  end

  test "the session detail page's MCP editor carries the same flags" do
    session = sessions(:active_session)

    with_mixed_availability_catalog { get session_url(session) }
    assert_response :success

    value = css_select("[data-editable-mcp-servers-available-servers-value]")
      .first["data-editable-mcp-servers-available-servers-value"]
    servers = JSON.parse(value)

    assert_equal true, servers.find { |s| s["name"] == "strad-secrets-staging-rw" }["unavailable"]
    assert_equal false, servers.find { |s| s["name"] == "context7" }["unavailable"]
  end

  # The turbo-stream re-render after a write goes through mcp_partials_locals,
  # which is a third copy of the payload. Without this the editor would show the
  # flags on load and lose them the moment you saved a change.
  test "the turbo-stream re-render after an MCP write carries the flags" do
    session = sessions(:active_session)

    with_mixed_availability_catalog do
      patch update_mcp_servers_session_url(session),
        params: { mcp_servers: [ "context7" ] },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :success

    value = css_select("[data-editable-mcp-servers-available-servers-value]")
      .first["data-editable-mcp-servers-available-servers-value"]
    servers = JSON.parse(value)

    assert_equal true, servers.find { |s| s["name"] == "strad-secrets-staging-rw" }["unavailable"]
    assert_equal "STRAD_STAGING_API_KEY unresolved",
      servers.find { |s| s["name"] == "strad-secrets-staging-rw" }["unavailable_reason"]
    assert_equal false, servers.find { |s| s["name"] == "context7" }["unavailable"]
  end

  # Test create action - success cases
  test "should create session" do
    assert_difference("Session.count") do
      post sessions_url, params: {
        session: {
          git_root: "https://github.com/test/repo.git",
          prompt: "Test prompt",
          mcp_servers: [ "playwright-custom", "twist-wolfbot" ]
        }
      }
    end

    assert_redirected_to session_path(Session.last)
  end

  # What the new-session form actually posts when no server is selected: the
  # multi-select emits one blank hidden input, which session_params strips to [].
  # That is a deliberate "no servers", and it has to survive to job start rather
  # than being healed back to the root's defaults.
  test "creating a session with no servers selected records a deliberate none" do
    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Test prompt",
        mcp_servers: [ "" ]
      }
    }

    session = Session.last
    assert_equal [], session.mcp_servers
    assert session.mcp_servers_explicitly_empty?
  end

  test "creating a session with servers selected records no deliberate none" do
    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Test prompt",
        mcp_servers: [ "playwright-custom" ]
      }
    }

    refute Session.last.mcp_servers_explicitly_empty?
  end

  test "should set default values on create" do
    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Test prompt",
        mcp_servers: []
      }
    }

    session = Session.last
    # Sessions start in waiting state; the job transitions them to running
    assert_equal "waiting", session.status
    assert_equal "claude_code", session.agent_runtime
  end

  test "should set model to opus by default on create" do
    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Test prompt",
        mcp_servers: []
      }
    }

    session = Session.last
    assert_equal "opus", session.config&.dig("model"),
      "Model should default to 'opus' when not explicitly set"
  end

  test "should use form-selected model on create" do
    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Test prompt",
        mcp_servers: []
      },
      model: "sonnet"
    }

    session = Session.last
    assert_equal "sonnet", session.config&.dig("model"),
      "Model should use the form-selected value"
  end

  test "should enqueue AgentSessionJob on create" do
    assert_enqueued_with(job: AgentSessionJob) do
      post sessions_url, params: {
        session: {
          git_root: "https://github.com/test/repo.git",
          prompt: "Test prompt",
          mcp_servers: [ "playwright-custom" ]
        }
      }
    end
  end

  test "should accept omitted mcp_servers array" do
    assert_difference("Session.count") do
      post sessions_url, params: {
        session: {
          git_root: "https://github.com/test/repo.git",
          prompt: "Test prompt without servers"
          # Don't include mcp_servers to test empty behavior
        }
      }
    end

    session = Session.last
    assert session.mcp_servers.nil? || session.mcp_servers.empty?
  end

  test "should strip blank mcp_servers values on create" do
    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Test prompt without servers",
        mcp_servers: [ "" ]
      }
    }

    session = Session.last
    assert_equal [], session.mcp_servers
  end

  test "should accept multiple mcp_servers" do
    servers = [ "playwright-custom", "twist-wolfbot", "context7" ]

    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Test with multiple servers",
        mcp_servers: servers
      }
    }

    session = Session.last
    assert_equal servers, session.mcp_servers
  end

  test "should display flash notice on successful create" do
    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Test prompt",
        mcp_servers: []
      }
    }

    assert_equal "Session created successfully. Starting agent...", flash[:notice]
  end

  # Test create action - clone-only sessions
  test "should create clone-only session without prompt" do
    # Clone-only sessions can be created without a prompt
    assert_difference("Session.count") do
      post sessions_url, params: {
        session: {
          git_root: "https://github.com/test/repo.git",
          prompt: "",
          mcp_servers: []
        }
      }
    end

    session = Session.last
    assert_equal "needs_input", session.status
    assert_equal "claude_code", session.agent_runtime
    assert session.prompt.blank?

    # Should redirect successfully
    assert_redirected_to session_path(session)
  end

  test "should display appropriate flash notice for clone-only session" do
    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "",
        mcp_servers: []
      }
    }

    assert_equal "Clone-only session created successfully. Ready for your first prompt.", flash[:notice]
  end

  test "should enqueue clone-only job for sessions without prompt" do
    assert_enqueued_with(job: AgentSessionJob) do
      post sessions_url, params: {
        session: {
          git_root: "https://github.com/test/repo.git",
          prompt: "",
          mcp_servers: []
        }
      }
    end

    # Check that the job was enqueued with clone_only flag
    job = enqueued_jobs.last
    assert_equal AgentSessionJob, job[:job]
    # The third argument (index 2) should be a hash with resume_monitoring: false and clone_only: true
    # ActiveJob serializes keyword arguments as string keys
    assert_equal false, job[:args][2]["resume_monitoring"]
    assert_equal true, job[:args][2]["clone_only"]
  end

  test "should allow follow-up prompt on clone-only session" do
    # Create a clone-only session first
    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "",
        mcp_servers: []
      }
    }

    session = Session.last
    assert_equal "needs_input", session.status

    # Simulate the session having been set up with a session_id
    session.update!(session_id: SecureRandom.uuid, metadata: { "working_directory" => "/tmp/test" })

    # Send a follow-up prompt
    assert_enqueued_with(job: AgentSessionJob) do
      post follow_up_session_path(session), params: {
        follow_up_prompt: "List files in the current directory"
      }
    end

    # Should redirect with success message
    assert_redirected_to session_path(session)
    assert_equal "Follow-up prompt sent. Agent is processing...", flash[:notice]

    session.reload
    assert_equal "running", session.status
  end

  # Test show action
  test "should show session" do
    session = sessions(:running)
    get session_url(session)
    assert_response :success
    # Prompt is no longer displayed on session detail page per Issue pulsemcp/agents#57
    # Check that session status is displayed instead (shown inline in header)
    assert_match session.status.titleize, response.body
  end

  # A normal full-page load renders the detail body WITHOUT the drawer's
  # <turbo-frame id="session_detail"> wrapper, so internal Turbo navigations
  # (follow-up form, infinite scroll, log-level filter) still target _top.
  test "show renders full-page without the drawer turbo-frame wrapper" do
    session = sessions(:running)
    get session_url(session)
    assert_response :success
    assert_select "turbo-frame#session_detail", false,
      "full-page show should not wrap content in the drawer's session_detail frame"
  end

  # The drawer variant lives at its own path and renders chrome-light, wrapped in
  # the frame the drawer panel swaps into.
  test "drawer renders the chrome-light frame variant for the session drawer" do
    session = sessions(:running)
    get drawer_session_url(session)
    assert_response :success
    # The matching frame is present so Turbo can swap it into the drawer.
    assert_select "turbo-frame#session_detail"
    # Layout is disabled — no surrounding application chrome (full <html> doc).
    assert_no_match(/<html/, response.body)
    # The detail body still streams live: its Turbo Stream subscriptions render.
    assert_match "session_#{session.id}_timeline", response.body
  end

  # A failed session's exception detail is rendered in full, inline, and
  # untruncated — the real root cause is frequently at the tail after a wall of
  # leading warnings, so truncating to 150 chars (the old behavior) hid it. The
  # detail must render in a scrollable <pre>, not behind a hover-only popover
  # that is unusable on mobile.
  test "show renders full untruncated exception detail for a failed session" do
    tail_marker = "ROOT_CAUSE_AT_THE_VERY_END_#{SecureRandom.hex(4)}"
    long_warnings = (1..80).map { |i| "warning: noisy preamble line #{i} that bloats the message" }.join("\n")
    exception_message = "#{long_warnings}\n#{tail_marker}"

    session = sessions(:failed)
    session.update!(
      metadata: (session.metadata || {}).merge(
        "failure_reason" => "exception",
        "exception_class" => "RuntimeError",
        "exception_message" => exception_message,
        "exit_status" => 1
      )
    )

    get session_url(session)
    assert_response :success

    # The full message — including the tail that the old 150-char truncate
    # dropped — must be present verbatim in the rendered HTML.
    assert_match tail_marker, response.body
    assert_match "warning: noisy preamble line 1 ", response.body

    # It renders in a scrollable monospace block (max-h-* + overflow-y-auto),
    # readable directly without a popover.
    assert_select "pre.overflow-y-auto", text: /#{Regexp.escape(tail_marker)}/

    # The exception detail no longer depends on the hover/click popover.
    assert_select '[data-error-popover-content-value*="ROOT_CAUSE_AT_THE_VERY_END"]', count: 0
  end

  # When an `air prepare` failure mixes a long, non-fatal deprecation warning
  # with the real error, the actionable error line is pulled into a prominent
  # "Actionable Error" callout ABOVE the full output — so the warning can't be
  # the first (and only visible) thing the user reads. The full output still
  # renders below, untruncated.
  test "show surfaces the actionable error above the warnings for a mixed air-prepare failure" do
    real_error = "Error: Unresolved variables in /clones/x: ${SENTRY_DSN}_#{SecureRandom.hex(4)}"
    warnings = (1..60).map { |i|
      "warning: Inline plugin bodies are deprecated as of v0.13.0 and will be removed (line #{i})"
    }.join("\n")
    exception_message = "#{warnings}\n#{real_error}"

    session = sessions(:failed)
    session.update!(
      metadata: (session.metadata || {}).merge(
        "failure_reason" => "exception",
        "exception_class" => "AirPrepareService::AirPrepareError",
        "exception_message" => exception_message,
        "exit_status" => 1
      )
    )

    get session_url(session)
    assert_response :success

    # The prominent callout is present and carries the real error.
    assert_select "pre.font-semibold", text: /#{Regexp.escape(real_error)}/

    # The callout leads with the actionable error, not the deprecation warning:
    # the error's first appearance in the HTML precedes the warning wall.
    error_pos = response.body.index(real_error)
    warning_pos = response.body.index("deprecated as of v0.13.0")
    assert error_pos, "actionable error must be rendered"
    assert warning_pos, "warning must still be rendered in the full output"
    assert error_pos < warning_pos,
      "actionable error (#{error_pos}) must appear before the first warning (#{warning_pos})"

    # The full, untruncated output is still available below the callout.
    assert_match "Full Output", response.body
    assert_match "deprecated as of v0.13.0 and will be removed (line 60)", response.body
  end

  # MCP-connection failures surface each failed server's full error in the same
  # untruncated scrollable block.
  test "show renders full untruncated mcp connection failure detail" do
    tail_marker = "MCP_TAIL_#{SecureRandom.hex(4)}"
    long_error = "#{(1..40).map { |i| "line #{i}" }.join(' ')} #{tail_marker}"

    session = sessions(:failed)
    session.update!(
      metadata: (session.metadata || {}).merge("failure_reason" => "mcp_connection_failed"),
      custom_metadata: (session.custom_metadata || {}).merge(
        "mcp_failed_servers" => [ { "name" => "some-server", "error" => long_error } ]
      )
    )

    get session_url(session)
    assert_response :success

    assert_match tail_marker, response.body
    assert_select "pre.overflow-y-auto", text: /#{Regexp.escape(tail_marker)}/
  end

  # The root cause of the drawer's intermittent "Content missing": /sessions/:id
  # used to serve two structurally different bodies — frameless full page, or
  # frame-wrapped drawer variant — chosen by the Turbo-Frame request header. Any
  # cache keyed on URL alone could then hand the frameless body to the drawer's
  # frame request, and the worst offender is not an HTTP cache at all: Turbo 8's
  # LinkPrefetchObserver stores a hover-prefetched request keyed ONLY by URL and
  # splices it into any later GET fetch for that URL, frame `src` loads included,
  # discarding the frame header entirely. `Vary` cannot reach that substitution
  # because it happens in browser memory and never touches the network.
  #
  # These two tests pin the fix: each URL has exactly ONE body, so there is no
  # variant for a cache to pick wrongly.
  test "show serves the same frameless body regardless of the Turbo-Frame header" do
    session = sessions(:running)

    get session_url(session)
    assert_response :success
    assert_select "turbo-frame#session_detail", false

    get session_url(session), headers: { "Turbo-Frame" => "session_detail" }
    assert_response :success
    assert_select "turbo-frame#session_detail", false,
      "/sessions/:id must not negotiate on Turbo-Frame — one URL, one body"
  end

  test "drawer serves the same framed body regardless of the Turbo-Frame header" do
    session = sessions(:running)

    get drawer_session_url(session)
    assert_response :success
    assert_select "turbo-frame#session_detail"

    get drawer_session_url(session), headers: { "Turbo-Frame" => "session_detail" }
    assert_response :success
    assert_select "turbo-frame#session_detail"
    assert_no_match(/<html/, response.body)
  end

  # When a session's frozen catalog columns are blank but its agent root still
  # declares defaults, the detail page surfaces those defaults as muted
  # "(agent root default)" tags instead of a permanent "None".
  test "show surfaces agent-root defaults when catalog columns are blank" do
    session = sessions(:running)
    session.update!(
      mcp_servers: [],
      catalog_skills: [],
      catalog_hooks: [],
      catalog_plugins: [],
      metadata: (session.metadata || {}).merge("agent_root_key" => "agent-orchestrator")
    )
    mock_root = OpenStruct.new(
      name: "agent-orchestrator",
      default_mcp_servers: [ "inherited-server" ],
      default_skills: [ "inherited-skill" ],
      default_hooks: [ "inherited-hook" ],
      default_plugins: [ "inherited-plugin" ]
    )
    AgentRootsConfig.stubs(:find_for_session).returns(mock_root)

    get session_url(session)
    assert_response :success

    # The current root defaults render in place of "None", clearly labeled.
    assert_match "inherited-server", response.body
    assert_match "inherited-skill", response.body
    assert_match "inherited-hook", response.body
    assert_match "inherited-plugin", response.body
    assert_match "(agent root default)", response.body

    # JS contract: the editable Stimulus controllers toggle these spans, so they
    # must still exist in the inherited-defaults branch or live edits silently break.
    assert_select '[data-role="skill-tags"]'
    assert_select '[data-role="skill-empty"]'
    assert_select '[data-role="hook-tags"]'
    assert_select '[data-role="hook-empty"]'
    assert_select '[data-role="plugin-tags"]'
    assert_select '[data-role="plugin-empty"]'
  end

  # A populated column wins — its captured badges render and the inherited
  # "(agent root default)" label is NOT shown for that artifact type.
  test "show does not show inherited label for populated catalog columns" do
    captured_skill = SkillsConfig.all.first.id
    session = sessions(:running)
    session.update!(
      catalog_skills: [ captured_skill ],
      metadata: (session.metadata || {}).merge("agent_root_key" => "agent-orchestrator")
    )
    mock_root = OpenStruct.new(
      name: "agent-orchestrator",
      default_mcp_servers: [],
      default_skills: [ "inherited-skill" ],
      default_hooks: [],
      default_plugins: []
    )
    AgentRootsConfig.stubs(:find_for_session).returns(mock_root)

    get session_url(session)
    assert_response :success

    assert_match captured_skill, response.body
    # The populated skills column wins; the root's default skill is not surfaced.
    assert_no_match(/inherited-skill/, response.body)
    assert_no_match(/\(agent root default\)/, response.body)
  end

  test "should display session information in show action" do
    session = sessions(:running)
    get session_url(session)

    assert_response :success
    # Session info is displayed inline in header per Issue pulsemcp/agents#57
    assert_match /Model:/, response.body
  end

  test "should display logs in show action" do
    session = sessions(:running)
    # Use verbose filter to ensure logs are visible (default is minimal which filters out logs)
    get session_url(session, filter: "verbose")

    assert_response :success
    # Logs should be visible on the page
    session.logs.each do |log|
      assert_match log.content, response.body
    end
  end

  test "should load job info in show action" do
    session = sessions(:running)
    get session_url(session)

    # @job_info may be nil if no job is found, which is expected
    # We just verify the method was called and didn't raise an error
    assert_response :success
  end

  test "should handle non-existent session" do
    # In integration tests, RecordNotFound is rescued by Rails
    # and returns a 404 response
    get session_url(id: 99999)
    assert_response :not_found
  end

  test "Root row shows agent root key and clipboard carries full path when subdirectory is set" do
    session = sessions(:running)
    home_dir = File.expand_path("~")
    clone_base = File.join(home_dir, ".zimmer", "clones")
    session.update!(
      subdirectory: "agent-orchestrator",
      metadata: {
        "agent_root_key" => "agent-orchestrator",
        "clone_path" => "#{clone_base}/agents-main-123-abc",
        "full_clone_path" => "#{clone_base}/agents-main-123-abc/agent-orchestrator"
      }
    )

    get session_url(session)
    assert_response :success

    # Root row displays the agent root key (not the filesystem path).
    # Match the visible text immediately after the "Root:" label up to the
    # closing </span> — the directory name must not appear in there.
    assert_match(%r{<strong>Root:</strong>\s*agent-orchestrator\s*</span>}, response.body)
    refute_match(%r{<strong>Root:</strong>[^<]*agents-main-123-abc}, response.body,
      "Root row's visible text should not leak the clone directory name")

    # Copy button still carries the full absolute path (prefers full_clone_path)
    expected_path = Regexp.escape("#{clone_base}/agents-main-123-abc/agent-orchestrator")
    assert_match(/data-clipboard-value="#{expected_path}"/, response.body)
  end

  test "Root row shows agent root key and clipboard carries clone_path when no subdirectory" do
    session = sessions(:running)
    home_dir = File.expand_path("~")
    clone_base = File.join(home_dir, ".zimmer", "clones")
    session.update!(
      subdirectory: nil,
      metadata: {
        "agent_root_key" => "agents",
        "clone_path" => "#{clone_base}/agents-main-123-abc"
      }
    )

    get session_url(session)
    assert_response :success

    # Root row displays the agent root key (not the filesystem path).
    assert_match(%r{<strong>Root:</strong>\s*agents\s*</span>}, response.body)
    refute_match(%r{<strong>Root:</strong>[^<]*agents-main-123-abc}, response.body,
      "Root row's visible text should not leak the clone directory name")

    # Copy button falls back to clone_path when full_clone_path is absent
    expected_path = Regexp.escape("#{clone_base}/agents-main-123-abc")
    assert_match(/data-clipboard-value="#{expected_path}"/, response.body)
  end

  test "Root row is omitted when session cannot be resolved to a catalog entry" do
    session = sessions(:running)
    session.update!(
      metadata: {
        "clone_path" => "/tmp/orphan-clone"
      }
    )

    get session_url(session)
    assert_response :success

    # No Root row rendered — agent_root_key could not be resolved
    refute_match(/<strong>Root:<\/strong>/, response.body)
  end

  # Test parameter filtering
  test "should permit prompt parameter" do
    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Allowed parameter",
        mcp_servers: []
      }
    }

    session = Session.last
    assert_equal "Allowed parameter", session.prompt
  end

  test "should permit mcp_servers parameter" do
    servers = [ "playwright-custom", "twist-wolfbot" ]

    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Test",
        mcp_servers: servers
      }
    }

    session = Session.last
    assert_equal servers, session.mcp_servers
  end

  test "should not allow setting status directly through params" do
    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Test",
        mcp_servers: [],
        status: :archived # Try to set status directly
      }
    }

    session = Session.last
    # Status should be waiting (initial state set by controller), not archived
    # Sessions start in waiting state and transition to running when the job begins
    assert_equal "waiting", session.status
  end

  test "should not allow setting agent_runtime through params" do
    post sessions_url, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Test",
        mcp_servers: [],
        agent_runtime: "malicious_agent" # Try to set agent_runtime directly
      }
    }

    session = Session.last
    # Agent type should be claude_code (set by controller)
    assert_equal "claude_code", session.agent_runtime
  end

  # Test routes
  test "should route root to index" do
    assert_routing({ method: :get, path: "/" }, { controller: "sessions", action: "index" })
  end

  test "should redirect /sessions to root" do
    get "/sessions"
    assert_response :redirect
    assert_redirected_to "/"
  end

  test "should route to new" do
    assert_routing({ method: :get, path: "/sessions/new" }, { controller: "sessions", action: "new" })
  end

  test "should route to create" do
    assert_routing({ method: :post, path: "/sessions" }, { controller: "sessions", action: "create" })
  end

  test "should route to show" do
    assert_routing({ method: :get, path: "/sessions/1" }, { controller: "sessions", action: "show", id: "1" })
  end

  # Archive action tests
  test "should archive failed session" do
    session = sessions(:failed)

    post archive_session_url(session)
    session.reload

    assert session.archived?
    assert_not_nil session.archived_at
    assert_redirected_to root_path
    assert_includes flash[:notice], "Session moved to trash."
    assert_includes flash[:notice], "undo_archive"
    assert_includes flash[:notice], session.id.to_s
  end

  test "should handle already archived session" do
    session = sessions(:archived)

    post archive_session_url(session)
    session.reload

    assert session.archived?
    assert_redirected_to session_path(session)
    assert_equal "Session is already in trash.", flash[:notice]
  end

  test "should create log entry naming the web UI as the actor when archiving" do
    session = sessions(:failed)

    # One log: the state machine's archive line, which carries the actor.
    assert_difference("session.logs.count", 1) do
      post archive_session_url(session)
    end

    log = session.logs.last
    assert_equal "[State Machine] Session moved to trash by a user in the web UI", log.content
  end

  test "archive should render turbo_stream that removes the session card target" do
    session = sessions(:failed)

    post archive_session_url(session), as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    assert_match(/<turbo-stream\s+action="remove"\s+target="session_#{session.id}"/, response.body)
    assert session.reload.archived?
  end

  # Archiving from the session page — or from the drawer showing it — leaves the
  # user looking at that page, so the reply has to flip its Trash button to
  # Restore itself. Session#broadcast_status_change pushes the same chrome over
  # the cable, but a cable can be silently dead and the direct reply cannot.
  test "archive turbo_stream carries the session page's own chrome" do
    session = sessions(:failed)

    post archive_session_url(session), as: :turbo_stream

    assert_response :success
    assert_match(/<turbo-stream\s+action="replace"\s+target="session_#{session.id}_status_badge"/, response.body)
    assert_match(/<turbo-stream\s+action="replace"\s+target="session_#{session.id}_header_actions"/, response.body)
    assert_match(/Restore/, response.body)
  end

  test "archive should render idempotent turbo_stream for already-archived session" do
    session = sessions(:archived)

    post archive_session_url(session), as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    assert_match(/<turbo-stream\s+action="remove"\s+target="session_#{session.id}"/, response.body)
  end

  # The human twin of the MCP/REST refusal. The first click does not archive: it
  # says what would be lost and offers "Archive anyway", which re-posts with
  # `force`. Every Trash affordance posts to this one action, so the two-step
  # covers the session header, the session card and the mobile joystick alike.
  test "archive refuses a session with a queued message and offers Archive anyway" do
    session = sessions(:failed)
    session.enqueued_messages.create!(content: "add the onion back", position: 1, status: "pending")

    post archive_session_url(session), as: :turbo_stream

    assert_response :success
    assert_not session.reload.archived?, "the first click must not archive"
    assert_equal "pending", session.enqueued_messages.sole.status
    assert_match(/1 queued message that has not been delivered/, response.body)
    assert_match(/Archive anyway/, response.body)
    # Pin the generated action, not just the word: this is what breaks if the
    # button stops carrying force, or the id parsed out of the flash regresses.
    assert_match(%r{action="/sessions/#{session.id}/archive\?force=1"}, response.body)
  end

  # The refusal holds an affordance the reader has to decide about behind a
  # confirm dialog, so it must not vanish on the bare-notice timer.
  test "the Archive anyway flash outlives the five-second notice timer" do
    session = sessions(:failed)
    session.enqueued_messages.create!(content: "still queued", position: 1, status: "pending")

    post archive_session_url(session), as: :turbo_stream

    assert_match(/data-flash-duration-value="30000"/, response.body)
  end

  test "archive refusal works on the non-turbo path too" do
    session = sessions(:failed)
    session.enqueued_messages.create!(content: "still queued", position: 1, status: "pending")

    post archive_session_url(session)

    assert_redirected_to session_path(session)
    assert_not session.reload.archived?
    assert_match(/force_archive/, flash[:alert].to_s)
  end

  test "archive ignores a force that is not truthy" do
    session = sessions(:failed)
    session.enqueued_messages.create!(content: "still queued", position: 1, status: "pending")

    post archive_session_url(session, force: "0"), as: :turbo_stream

    assert_not session.reload.archived?
  end

  test "archive with force discards the queue and archives" do
    session = sessions(:failed)
    queued = session.enqueued_messages.create!(content: "discarded", position: 1, status: "pending")

    post archive_session_url(session, force: 1), as: :turbo_stream

    assert_response :success
    assert session.reload.archived?
    assert_equal "undelivered", queued.reload.status
    # Forcing chooses the discard; it must not hide it.
    line = session.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_includes line, "1 queued message was never delivered"
    assert_includes line, "discarded"
  end

  # The whitelist gates a destructive affordance on a string convention, so a
  # message that is not one of the two known actions must render verbatim.
  test "an unknown flash action renders as text with no button" do
    # Driven directly: no controller emits an unknown action, and the point is
    # the partial's whitelist rather than any one caller.
    rendered = ApplicationController.render(
      partial: "shared/flash",
      locals: { messages: { "alert" => "something|not_an_action|1" } }
    )

    assert_includes rendered, "something|not_an_action|1"
    assert_not_includes rendered, "Archive anyway"
    assert_not_includes rendered, "Undo"
  end

  test "archive still works normally when nothing is queued" do
    session = sessions(:failed)

    post archive_session_url(session), as: :turbo_stream

    assert_response :success
    assert session.reload.archived?
  end

  # A bulk selection is not a claim to have read each session's queue, so those
  # are skipped rather than forced — and the count says so.
  test "bulk_archive skips sessions with queued messages and says how many" do
    blocked = sessions(:failed)
    blocked.enqueued_messages.create!(content: "still queued", position: 1, status: "pending")
    archivable = sessions(:needs_input)

    post bulk_archive_sessions_url, params: { session_ids: [ blocked.id, archivable.id ] }

    assert_not blocked.reload.archived?
    assert archivable.reload.archived?
    assert_match(/1 skipped/, flash[:notice].to_s)
  end

  # Undo archive action tests
  test "should undo archive within 5-second window" do
    session = sessions(:failed)
    session.update!(status: :archived, archived_at: 1.second.ago)

    post undo_archive_session_url(session)
    session.reload

    assert_not session.archived?
    assert_nil session.archived_at
    assert_redirected_to session_path(session)
    assert_equal "Session restored from trash.", flash[:notice]
  end

  test "should reject undo archive after 5-second window" do
    session = sessions(:failed)
    session.update!(status: :archived, archived_at: 6.seconds.ago)

    post undo_archive_session_url(session)
    session.reload

    assert session.archived?
    assert_redirected_to root_path
    assert_equal "The undo window has expired. Use the restore feature instead.", flash[:alert]
  end

  test "should reject undo archive for non-archived session" do
    session = sessions(:running)

    post undo_archive_session_url(session)

    assert_redirected_to root_path
    assert_equal "Session is not in trash.", flash[:alert]
  end

  # === Turbo Stream responses for the dashboard's mutating actions ===
  #
  # These actions used to redirect purely to carry a flash, which meant a full
  # page render for every trash / refresh / pause. They now stream the message
  # into the layout's #flash target instead; the HTML branch still redirects for
  # non-Turbo clients, which the tests above cover.

  test "archive turbo_stream carries the Undo affordance into the flash target" do
    session = sessions(:failed)

    post archive_session_url(session), as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    # The card goes away...
    assert_match(/<turbo-stream\s+action="remove"\s+target="session_#{session.id}"/, response.body)
    # ...and the toast that offers to bring it back arrives with it.
    assert_match(/<turbo-stream\s+action="replace"\s+target="flash"/, response.body)
    assert_match(/Session moved to trash\./, response.body)
    assert_match %r{action="#{Regexp.escape(undo_archive_session_path(session))}"}, response.body
    assert_match(/>Undo</, response.body)
  end

  test "archive turbo_stream for an already-archived session still explains itself" do
    session = sessions(:archived)

    post archive_session_url(session), as: :turbo_stream

    assert_response :success
    assert_match(/<turbo-stream\s+action="remove"\s+target="session_#{session.id}"/, response.body)
    assert_match(/<turbo-stream\s+action="replace"\s+target="flash"/, response.body)
    assert_match(/Session is already in trash\./, response.body)
  end

  test "undo_archive turbo_stream puts the card back and does not redirect" do
    session = sessions(:failed)
    session.update!(status: :archived, archived_at: 1.second.ago)

    post undo_archive_session_url(session), as: :turbo_stream

    assert_response :success
    assert_not session.reload.archived?
    # Uncategorized sessions land in the Uncategorized grid.
    assert_match(/<turbo-stream\s+action="prepend"\s+target="sessions_grid"/, response.body)
    assert_match(/id="session_#{session.id}"/, response.body)
    assert_match(/<turbo-stream\s+action="replace"\s+target="flash"/, response.body)
    assert_match(/Session restored from trash\./, response.body)
  end

  test "undo_archive turbo_stream returns a categorized card to its own category grid" do
    category = Category.create!(name: "Turbo stream target")
    session = sessions(:failed)
    session.update!(category_id: category.id, status: :archived, archived_at: 1.second.ago)

    post undo_archive_session_url(session), as: :turbo_stream

    assert_response :success
    assert_match(/<turbo-stream\s+action="prepend"\s+target="category_grid_#{category.id}"/, response.body)
  end

  test "undo_archive turbo_stream sends a categorized card to the flat grid in a flat view" do
    # The flat sort views render one #sessions_grid and no per-category grids, so
    # prepending to category_grid_<id> there would drop the card silently.
    category = Category.create!(name: "Flat view target")
    session = sessions(:failed)
    session.update!(category_id: category.id, status: :archived, archived_at: 1.second.ago)

    cookies[SessionsController::VIEW_MODE_COOKIE] = SessionsController::VIEW_MODE_LAST_TOUCHED
    post undo_archive_session_url(session), as: :turbo_stream

    assert_response :success
    assert_match(/<turbo-stream\s+action="prepend"\s+target="sessions_grid"/, response.body)
    assert_no_match(/target="category_grid_#{category.id}"/, response.body)
  end

  test "undo_archive turbo_stream sends a categorized card to the flat grid while searching" do
    category = Category.create!(name: "Search view target")
    session = sessions(:failed)
    session.update!(category_id: category.id, status: :archived, archived_at: 1.second.ago)

    cookies[SessionsController::VIEW_MODE_COOKIE] = SessionsController::VIEW_MODE_CATEGORIES
    post undo_archive_session_url(session),
      headers: { "HTTP_REFERER" => root_url(q: "anything") },
      as: :turbo_stream

    assert_response :success
    assert_match(/<turbo-stream\s+action="prepend"\s+target="sessions_grid"/, response.body)
    assert_no_match(/target="category_grid_#{category.id}"/, response.body)
  end

  test "a flash message containing a pipe is shown whole, not truncated at it" do
    # "text|action|id" is how the archive notice attaches its Undo button. A
    # message whose own prose contains a pipe must not be parsed as one.
    category = Category.create!(name: "Design|Research")
    session = sessions(:running)

    patch set_category_session_url(session), params: { category_id: category.id }, as: :turbo_stream

    assert_response :success
    assert_match(/Moved to &quot;Design\|Research&quot;\./, response.body)
    assert_no_match(/>Undo</, response.body)
  end

  test "undo_archive turbo_stream streams the expiry alert instead of redirecting" do
    session = sessions(:failed)
    session.update!(status: :archived, archived_at: 6.seconds.ago)

    post undo_archive_session_url(session), as: :turbo_stream

    assert_response :success
    assert session.reload.archived?
    assert_match(/<turbo-stream\s+action="replace"\s+target="flash"/, response.body)
    assert_match(/The undo window has expired/, response.body)
  end

  test "bulk_archive turbo_stream streams the count into the flash target" do
    session = sessions(:failed)

    post bulk_archive_sessions_url, params: { session_ids: [ session.id ] }, as: :turbo_stream

    assert_response :success
    assert session.reload.archived?
    assert_match(/<turbo-stream\s+action="replace"\s+target="flash"/, response.body)
    assert_match(/1 session\(s\) moved to trash\./, response.body)
  end

  test "bulk_archive turbo_stream streams the empty-selection alert" do
    # No `session_ids` at all: form-encoding an empty array sends `session_ids[]=`,
    # which arrives as [""] and is not empty. The existing HTML test for this
    # branch omits the param the same way.
    post bulk_archive_sessions_url, as: :turbo_stream

    assert_response :success
    assert_match(/<turbo-stream\s+action="replace"\s+target="flash"/, response.body)
    assert_match(/No sessions selected\./, response.body)
  end

  test "refresh_all turbo_stream streams its summary instead of redirecting" do
    # Nothing to refresh keeps the action off the restart/continue paths that
    # would reach for real processes; the response shape is what is under test.
    Session.where.not(status: :archived).update_all(status: :archived)

    post refresh_all_sessions_url, as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    assert_match(/<turbo-stream\s+action="replace"\s+target="flash"/, response.body)
    assert_match(/No non-archived sessions to refresh/, response.body)
  end

  test "refresh_category turbo_stream streams the unknown-category alert" do
    post refresh_category_sessions_url, params: { category_id: 999_999 }, as: :turbo_stream

    assert_response :success
    assert_match(/<turbo-stream\s+action="replace"\s+target="flash"/, response.body)
    assert_match(/Category not found/, response.body)
  end

  test "refresh_category turbo_stream streams the frozen-category refusal" do
    category = Category.create!(name: "Parked", is_frozen: true)

    post refresh_category_sessions_url, params: { category_id: category.id }, as: :turbo_stream

    assert_response :success
    assert_match(/Frozen categories are excluded from refresh/, response.body)
  end

  test "pause turbo_stream streams the not-running refusal" do
    session = sessions(:needs_input)

    post pause_session_url(session), as: :turbo_stream

    assert_response :success
    assert_match(/<turbo-stream\s+action="replace"\s+target="flash"/, response.body)
    assert_match(/Cannot pause session that is not running/, response.body)
  end

  test "unarchive turbo_stream carries the session page's own chrome" do
    # A broadcast is fire-and-forget; the reply to the user's own click is not.
    # A status-changing action therefore re-renders the badge and header actions
    # itself rather than trusting the cable to be up. The restore service is
    # stubbed because what is under test is the response's shape, not the clone
    # and transcript work behind it (covered by UnarchiveSessionService's tests).
    session = sessions(:archived)
    UnarchiveSessionService.stubs(:call).returns(
      UnarchiveSessionService::Result.new(success?: true, session: session, clone_restored: false)
    )

    post unarchive_session_url(session), as: :turbo_stream

    assert_response :success
    assert_match(/<turbo-stream\s+action="replace"\s+target="session_#{session.id}_status_badge"/, response.body)
    assert_match(/<turbo-stream\s+action="replace"\s+target="session_#{session.id}_header_actions"/, response.body)
    assert_match(/<turbo-stream\s+action="replace"\s+target="flash"/, response.body)
    assert_match(/Session restored from trash\. Ready to continue\./, response.body)
  end

  # zimmer#557: the web UI's Restore button runs the same code as the MCP
  # "unarchive" action, and a session archived before its agent process ever
  # launched failed on both with "Failed to restore: Session has no session_id".
  # Trash presents itself as reversible; for these sessions it was not.
  test "unarchive restores a session that never ran rather than refusing it" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Investigate the flaky test",
      status: :archived,
      archived_at: 1.hour.ago,
      metadata: { "paused_by" => "recovery" }
    )
    assert session.never_ran?

    post unarchive_session_url(session), as: :turbo_stream

    assert_response :success
    assert_match(/Session restored from trash\. Ready to continue\./, response.body)
    assert_no_match(/Failed to restore/, response.body)

    session.reload
    assert_equal "needs_input", session.status
    assert_nil session.archived_at
  end

  test "unarchive turbo_stream streams the not-in-trash refusal" do
    session = sessions(:running)

    post unarchive_session_url(session), as: :turbo_stream

    assert_response :success
    assert_match(/<turbo-stream\s+action="replace"\s+target="flash"/, response.body)
    assert_match(/Session is not in trash\./, response.body)
  end

  test "set_category turbo_stream confirms the move" do
    category = Category.create!(name: "Streamed move")
    session = sessions(:running)

    patch set_category_session_url(session), params: { category_id: category.id }, as: :turbo_stream

    assert_response :success
    assert_equal category.id, session.reload.category_id
    assert_match(/<turbo-stream\s+action="replace"\s+target="flash"/, response.body)
    assert_match(/Moved to &quot;Streamed move&quot;\./, response.body)
  end

  test "set_category turbo_stream confirms a move back to Uncategorized" do
    category = Category.create!(name: "Streamed move back")
    session = sessions(:running)
    session.update!(category_id: category.id)

    patch set_category_session_url(session), params: { category_id: "" }, as: :turbo_stream

    assert_response :success
    assert_nil session.reload.category_id
    assert_match(/Moved to Uncategorized\./, response.body)
  end

  test "a streamed flash is not also replayed on the next page load" do
    session = sessions(:failed)

    post archive_session_url(session), as: :turbo_stream
    assert_response :success

    get root_url
    assert_response :success
    assert_no_match(/Session moved to trash/, response.body)
  end

  test "should create log entry when undoing archive" do
    session = sessions(:failed)
    session.update!(status: :archived, archived_at: 1.second.ago)

    # State machine creates 1 log + controller creates 1 log = 2 logs total
    assert_difference("session.logs.count", 2) do
      post undo_archive_session_url(session)
    end

    log = session.logs.last
    assert_includes log.content, "restored from trash"
  end

  # Bulk archive action tests
  test "should bulk archive multiple sessions" do
    failed_session = sessions(:failed)
    failed_session2 = Session.create!(
      agent_runtime: "claude_code",
      status: :failed,
      prompt: "Another failed task",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )

    post bulk_archive_sessions_url, params: {
      session_ids: [ failed_session.id, failed_session2.id ]
    }

    failed_session.reload
    failed_session2.reload

    assert failed_session.archived?
    assert failed_session2.archived?
    assert_redirected_to root_path
    assert_includes flash[:notice], "2 session(s) moved to trash"
    assert_equal "[State Machine] Session moved to trash by a user in the web UI (bulk action)",
                 failed_session.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
  end

  test "should handle empty bulk archive selection" do
    post bulk_archive_sessions_url

    assert_redirected_to root_path
    assert_equal "No sessions selected.", flash[:alert]
  end

  test "should create log entries for bulk archived sessions" do
    failed_session = sessions(:failed)
    failed_session2 = Session.create!(
      agent_runtime: "claude_code",
      status: :failed,
      prompt: "Another failed task",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )

    # One log per archive: the state machine's line, which carries the actor.
    assert_difference("Log.count", 2) do
      post bulk_archive_sessions_url, params: {
        session_ids: [ failed_session.id, failed_session2.id ]
      }
    end

    [ failed_session, failed_session2 ].each do |session|
      assert_equal "[State Machine] Session moved to trash by a user in the web UI (bulk action)",
                   session.logs.sole.content
    end
  end

  # Index filtering tests
  test "should hide archived sessions by default" do
    archived_session = sessions(:archived)
    needs_input_session = sessions(:needs_input)

    get root_url

    assert_response :success
    # Archived session should not be in the response (check using session path)
    assert_not response.body.include?(session_path(archived_session))
    # But the needs_input session — the default filter — should be
    assert response.body.include?(session_path(needs_input_session))
  end

  test "should show archived sessions when the status filter selects them" do
    archived_session = sessions(:archived)

    get root_url(every_status_params(status: [ "archived" ]))

    assert_response :success
    # Archived session should be in the response (check using session path)
    assert response.body.include?(session_path(archived_session))
  end

  test "index renders the Filters section with a checkbox per status" do
    get root_url

    assert_response :success
    assert_select "h2", text: "Filters"
    SessionsController::STATUS_FILTER_OPTIONS.each do |status|
      assert_select "input[type=checkbox][name='status[]'][value=?]", status, count: 1
    end
    # The default state is needs_input alone, pre-ticked.
    assert_select "input#status-filter-needs-input[checked]", count: 1
    assert_select "input[name='status[]'][checked]", count: 1
    assert_select "a#reset-filters", count: 1
  end

  # Test follow_up action
  test "should follow up on waiting session" do
    session = sessions(:waiting)

    assert_enqueued_with(job: AgentSessionJob) do
      post follow_up_session_url(session), params: {
        follow_up_prompt: "Continue with next step"
      }
    end

    session.reload
    assert_equal "running", session.status
    assert_redirected_to session_path(session)
    assert_equal "Follow-up prompt sent. Agent is processing...", flash[:notice]
  end

  test "should follow up on needs_input session" do
    session = sessions(:needs_input)

    post follow_up_session_url(session), params: {
      follow_up_prompt: "Here is the requested input"
    }

    session.reload
    assert_equal "running", session.status
    assert_redirected_to session_path(session)
  end

  # NOTE: This test was updated as part of issue pulsemcp/agents#592 fix.
  # Previously, follow_up on a running session would pause and send immediately.
  # Now, to prevent race conditions, follow_up on a running session queues the message.
  test "should queue follow up on running session instead of sending immediately" do
    session = sessions(:running)
    # Add a fake PID (not used anymore since we queue instead of pausing)
    session.update!(metadata: { "process_pid" => 999999 })

    post follow_up_session_url(session), params: {
      follow_up_prompt: "This should be queued"
    }

    session.reload
    # Session should still be running (no interrupt), message should be queued
    assert_equal "running", session.status
    assert_equal 1, session.enqueued_messages.count, "Message should be queued"
    assert_equal "This should be queued", session.enqueued_messages.first.content
    assert_redirected_to session_path(session)
    assert_includes flash[:notice], "queued"
  end

  # A Turbo Frame follows a redirect with its own Turbo-Frame header still
  # attached and then looks for a matching frame in the result. /sessions/:id is
  # frameless by construction, so a redirect there from the drawer's follow-up
  # form lands on a body with no frame and renders "Content missing" — the drawer
  # bug reached through a redirect instead of through a poisoned cache. These two
  # actions are the ones that redirect rather than answering with a Turbo Stream.
  test "follow_up on a running session redirects the drawer frame to the drawer url" do
    session = sessions(:running)
    session.update!(metadata: { "process_pid" => 999999 })

    post follow_up_session_url(session),
      params: { follow_up_prompt: "Queued from the drawer" },
      headers: { "Turbo-Frame" => "session_detail" }

    assert_redirected_to drawer_session_path(session)
  end

  test "refresh redirects the drawer frame to the drawer url" do
    session = sessions(:running)

    post refresh_session_url(session), headers: { "Turbo-Frame" => "session_detail" }
    assert_redirected_to drawer_session_path(session)

    # Outside the drawer the full page is still the right destination.
    post refresh_session_url(session)
    assert_redirected_to session_path(session)
  end

  # A redirect is the other way the drawer can end up on a frameless body. The
  # drawer's follow-up form carries no frame target, so Turbo scopes the POST to
  # session_detail and follows the 302 with that header still attached, then looks
  # for a matching frame in the result. /sessions/:id has none by construction, so
  # a redirect there renders "Content missing" — the bug the drawer's own URL
  # exists to prevent, arrived at by a different door.
  test "a queued follow-up from the drawer redirects to the drawer, not the frameless page" do
    session = sessions(:running)
    session.update!(metadata: { "process_pid" => 999999 })

    post follow_up_session_url(session),
      params: { follow_up_prompt: "Queued from the drawer" },
      headers: { "Turbo-Frame" => "session_detail" }

    assert_redirected_to drawer_session_path(session)
  end

  # Same door, second latch: #refresh has no turbo_stream branch, so every exit is
  # a redirect. From the drawer without a dashboard referer it fell back to the
  # frameless session page.
  test "refresh from the drawer redirects to the drawer, not the frameless page" do
    session = sessions(:running)

    post refresh_session_url(session), headers: { "Turbo-Frame" => "session_detail" }

    assert_redirected_to drawer_session_path(session)
  end

  test "refresh outside the drawer still redirects to the full session page" do
    session = sessions(:running)

    post refresh_session_url(session)

    assert_redirected_to session_path(session)
  end

  test "should not follow up on archived session" do
    session = sessions(:archived)

    post follow_up_session_url(session), params: {
      follow_up_prompt: "This should not work"
    }

    session.reload
    assert_equal "archived", session.status
    assert_redirected_to session_path(session)
    assert_includes flash[:alert], "Cannot send follow-up prompts"
  end

  test "should not follow up with empty prompt" do
    session = sessions(:waiting)

    post follow_up_session_url(session), params: {
      follow_up_prompt: ""
    }

    session.reload
    assert_equal "waiting", session.status
    assert_redirected_to session_path(session)
    assert_equal "Follow-up prompt cannot be empty.", flash[:alert]
  end

  test "should reject follow up prompt exceeding maximum length" do
    session = sessions(:waiting)
    long_prompt = "x" * (Session::PROMPT_MAX_LENGTH + 1)

    post follow_up_session_url(session), params: {
      follow_up_prompt: long_prompt
    }

    session.reload
    assert_equal "waiting", session.status # Should remain waiting due to error
    assert_redirected_to session_path(session)
    assert_includes flash[:alert], "Follow-up prompt is too long"
  end

  test "should create log entry when following up" do
    session = sessions(:waiting)

    # State machine creates 1 log (resume) + controller creates 1 log = 2 logs total
    assert_difference("session.logs.count", 2) do
      post follow_up_session_url(session), params: {
        follow_up_prompt: "Continue with implementation"
      }
    end

    log = session.logs.last
    assert_includes log.content, "Follow-up prompt received"
    assert_includes log.content, "Continue with implementation"
  end

  test "should update goal when following up" do
    session = sessions(:waiting)
    session.update!(goal: "Original condition")

    post follow_up_session_url(session), params: {
      follow_up_prompt: "Continue",
      goal: "New goal"
    }

    session.reload
    assert_equal "New goal", session.goal
    assert_redirected_to session_path(session)

    # Should create log entry for goal update
    goal_log = session.logs.find { |log| log.content.include?("Goal") }
    assert_not_nil goal_log
    assert_includes goal_log.content, "updated"
  end

  test "should remove goal when following up with empty string" do
    session = sessions(:waiting)
    session.update!(goal: "Existing condition")

    post follow_up_session_url(session), params: {
      follow_up_prompt: "Continue",
      goal: ""
    }

    session.reload
    assert_nil session.goal
    assert_redirected_to session_path(session)

    # Should create log entry for goal removal
    goal_log = session.logs.find { |log| log.content.include?("Goal") }
    assert_not_nil goal_log
    assert_includes goal_log.content, "removed"
  end

  test "should keep goal unchanged when not provided in params" do
    session = sessions(:waiting)
    original_condition = "Keep this condition"
    session.update!(goal: original_condition)

    post follow_up_session_url(session), params: {
      follow_up_prompt: "Continue"
      # Not providing goal param at all
    }

    session.reload
    assert_equal original_condition, session.goal
    assert_redirected_to session_path(session)

    # Should not create log entry for goal (unchanged)
    goal_logs = session.logs.select { |log| log.content.include?("Goal") }
    assert_empty goal_logs
  end

  test "should reject goal exceeding maximum length" do
    session = sessions(:waiting)
    long_condition = "x" * (Session::GOAL_MAX_LENGTH + 1)

    post follow_up_session_url(session), params: {
      follow_up_prompt: "Continue",
      goal: long_condition
    }

    session.reload
    assert_equal "waiting", session.status # Should remain waiting due to error
    assert_redirected_to session_path(session)
    assert_includes flash[:alert], "Goal is too long"
  end

  # Turbo Stream response tests - verify the optimistic message fix works correctly
  # These tests ensure the follow_up action responds with Turbo Stream to avoid
  # page reload, which would cause the optimistic message to disappear.

  test "follow_up should return turbo_stream response with form replacement on success" do
    session = sessions(:needs_input)
    session.update!(metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" })

    post follow_up_session_url(session), params: {
      follow_up_prompt: "Continue with implementation"
    }, as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    # Should replace the follow-up form
    assert_match(/turbo-stream/, response.body)
    assert_match(/action="replace"/, response.body)
    assert_match(/session_#{session.id}_follow_up_form/, response.body)

    session.reload
    assert_equal "running", session.status
  end

  test "follow_up error should return turbo_stream with error message for empty prompt" do
    session = sessions(:waiting)

    post follow_up_session_url(session), params: {
      follow_up_prompt: ""
    }, as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    # Should include error message and form replacement
    assert_match(/enqueued_messages_form_errors/, response.body)
    assert_match(/Follow-up prompt cannot be empty/, response.body)

    session.reload
    assert_equal "waiting", session.status
  end

  test "follow_up error should return turbo_stream with error message for prompt too long" do
    session = sessions(:waiting)
    long_prompt = "x" * (Session::PROMPT_MAX_LENGTH + 1)

    post follow_up_session_url(session), params: {
      follow_up_prompt: long_prompt
    }, as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    assert_match(/enqueued_messages_form_errors/, response.body)
    assert_match(/Follow-up prompt is too long/, response.body)

    session.reload
    assert_equal "waiting", session.status
  end

  test "should reset all stale retry metadata on follow_up" do
    session = sessions(:needs_input)

    session.update!(
      metadata: (session.metadata || {}).merge(
        "sigterm_retry_count" => 3,
        "sigterm_retry_timestamps" => [ "2025-11-29T18:21:47Z", "2025-11-29T18:22:09Z", "2025-11-29T18:25:40Z" ],
        "last_sigterm_at" => "2025-11-29T18:25:40Z",
        "exit_status" => "Account quota limit reached — retry skipped",
        "last_quota_limit_at" => "2026-04-11T22:44:07Z",
        "last_quota_limit_message" => "You've hit your limit · resets 11pm (UTC)",
        "quota_limit_count" => 1,
        "clone_path" => "/tmp/test-clone"
      )
    )

    post follow_up_session_url(session), params: {
      follow_up_prompt: "Continue with the task"
    }

    session.reload
    # All STALE_RETRY_METADATA_KEYS should be cleared
    assert_nil session.metadata["sigterm_retry_count"]
    assert_nil session.metadata["sigterm_retry_timestamps"]
    assert_nil session.metadata["last_sigterm_at"]
    assert_nil session.metadata["exit_status"]
    assert_nil session.metadata["last_quota_limit_at"]
    assert_nil session.metadata["last_quota_limit_message"]
    assert_nil session.metadata["quota_limit_count"]
    # Non-stale metadata should be preserved
    assert_equal "/tmp/test-clone", session.metadata["clone_path"]
    assert_equal "running", session.status
    assert_redirected_to session_path(session)
  end

  test "should not modify metadata if no stale retry state exists on follow_up" do
    session = sessions(:waiting)

    # Set up metadata without SIGTERM retry state
    original_metadata = { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" }
    session.update!(metadata: original_metadata)

    post follow_up_session_url(session), params: {
      follow_up_prompt: "Continue with the task"
    }

    session.reload
    # Metadata should be unchanged (except potentially for auto-added fields)
    assert_equal "/tmp/test-clone", session.metadata["clone_path"]
    assert_equal "/tmp/test-clone", session.metadata["working_directory"]
    assert_equal "running", session.status
  end

  test "should store pending_follow_up_prompt in metadata on follow_up" do
    session = sessions(:needs_input)

    # Set up metadata
    session.update!(
      metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" }
    )

    post follow_up_session_url(session), params: {
      follow_up_prompt: "Please fix the bug"
    }

    session.reload
    # Verify the pending follow-up prompt was stored in metadata
    assert_equal "Please fix the bug", session.metadata["pending_follow_up_prompt"]
    assert_equal "running", session.status
    assert_redirected_to session_path(session)
  end

  test "should store sent_message in metadata on follow_up for recovery" do
    session = sessions(:needs_input)

    # Set up metadata
    session.update!(
      metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" }
    )

    freeze_time do
      post follow_up_session_url(session), params: {
        follow_up_prompt: "Please implement the feature"
      }

      session.reload
      # Verify the sent_message was stored in metadata for recovery
      assert_equal "Please implement the feature", session.metadata["sent_message"]
      assert_equal Time.current.iso8601, session.metadata["sent_message_at"]
      assert_equal "running", session.status
    end
  end

  test "follow_up should set running_job_id immediately to prevent orphaned running sessions" do
    session = sessions(:needs_input)
    session.update!(
      metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" },
      running_job_id: nil
    )

    post follow_up_session_url(session), params: {
      follow_up_prompt: "continue working"
    }

    session.reload
    assert_equal "running", session.status
    # running_job_id must be set immediately by the controller, not deferred to the job.
    # This prevents a window where the session is "running" with no tracked job.
    assert_not_nil session.running_job_id, "running_job_id should be set by the controller on follow-up"
  end

  # Test for the fix to pulsemcp/agents#592 - follow_up should queue messages when
  # session is running
  # This prevents race conditions where form action is set incorrectly
  test "follow_up should queue message instead of sending when session is running" do
    session = sessions(:running)

    # Ensure session is truly running
    assert session.running?, "Session should be running for this test"
    assert_equal 0, session.enqueued_messages.count, "Session should have no enqueued messages initially"

    post follow_up_session_url(session), params: {
      follow_up_prompt: "This should be queued"
    }

    session.reload
    # Message should be queued, not sent immediately
    assert_equal 1, session.enqueued_messages.count, "Message should be queued"
    assert_equal "This should be queued", session.enqueued_messages.first.content
    assert_equal "pending", session.enqueued_messages.first.status
    # Session should still be running (not paused for interrupt)
    assert session.running?, "Session should still be running"
    assert_redirected_to session_path(session)
    follow_redirect!
    assert_match /queued/i, flash[:notice]
  end

  test "follow_up should queue message with goal when session is running" do
    session = sessions(:running)

    post follow_up_session_url(session), params: {
      follow_up_prompt: "Run the tests",
      goal: "All tests pass"
    }

    session.reload
    assert_equal 1, session.enqueued_messages.count
    message = session.enqueued_messages.first
    assert_equal "Run the tests", message.content
    assert_equal "All tests pass", message.goal
    assert session.running?, "Session should still be running"
  end

  test "follow_up should send immediately when session is needs_input" do
    session = sessions(:needs_input)
    session.update!(metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" })

    post follow_up_session_url(session), params: {
      follow_up_prompt: "This should be sent immediately"
    }

    session.reload
    # Message should be sent immediately, not queued
    assert_equal 0, session.enqueued_messages.count, "Message should not be queued"
    # Session should be running now (job was enqueued)
    assert session.running?, "Session should be running after follow-up"
  end

  # Routes tests for new actions
  test "should route to archive" do
    assert_routing(
      { method: :post, path: "/sessions/1/archive" },
      { controller: "sessions", action: "archive", id: "1" }
    )
  end

  test "should route to bulk_archive" do
    assert_routing(
      { method: :post, path: "/sessions/bulk_archive" },
      { controller: "sessions", action: "bulk_archive" }
    )
  end

  test "should route to follow_up" do
    assert_routing(
      { method: :post, path: "/sessions/1/follow_up" },
      { controller: "sessions", action: "follow_up", id: "1" }
    )
  end

  # Test update_title action
  test "should update session title" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")

    patch update_title_session_url(session), params: { title: "New Title" }, as: :json

    assert_response :success
    session.reload
    assert_equal "New Title", session.title

    json_response = JSON.parse(response.body)
    assert_equal true, json_response["success"]
    assert_equal "New Title", json_response["title"]
  end

  test "should create log when updating title" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")

    assert_difference "session.logs.count", 1 do
      patch update_title_session_url(session), params: { title: "New Title" }, as: :json
    end

    session.reload
    log = session.logs.last
    assert_equal "info", log.level
    assert_includes log.content, "Session title updated to: New Title"
  end

  test "should reject empty title" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    # Manually set title to avoid auto-generated default
    session.update_columns(title: "Old Title", metadata: {})

    patch update_title_session_url(session), params: { title: "" }, as: :json

    assert_response :unprocessable_entity
    session.reload
    assert_equal "Old Title", session.title

    json_response = JSON.parse(response.body)
    assert_includes json_response["error"], "Title cannot be empty"
  end

  test "should reject blank title" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    # Manually set title to avoid auto-generated default
    session.update_columns(title: "Old Title", metadata: {})

    patch update_title_session_url(session), params: { title: "   " }, as: :json

    assert_response :unprocessable_entity
    session.reload
    assert_equal "Old Title", session.title
  end

  test "should reject title that is too long" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    long_title = "a" * 101
    # Store the default title for comparison
    default_title = session.title

    patch update_title_session_url(session), params: { title: long_title }, as: :json

    assert_response :unprocessable_entity
    session.reload
    assert_equal default_title, session.title

    json_response = JSON.parse(response.body)
    assert_includes json_response["error"], "Title is too long"
  end

  test "should accept title at maximum length" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    max_title = "a" * 100

    patch update_title_session_url(session), params: { title: max_title }, as: :json

    assert_response :success
    session.reload
    assert_equal max_title, session.title
  end

  test "should strip whitespace from title" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")

    patch update_title_session_url(session), params: { title: "  Title with spaces  " }, as: :json

    assert_response :success
    session.reload
    assert_equal "Title with spaces", session.title
  end

  test "should route to update_title" do
    assert_routing(
      { method: :patch, path: "/sessions/1/update_title" },
      { controller: "sessions", action: "update_title", id: "1" }
    )
  end

  # Test update_notes action
  test "should update session notes" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")

    patch update_notes_session_url(session), params: { session_notes: "My notes" }, as: :json

    assert_response :success
    session.reload
    assert_equal "My notes", session.session_notes
    assert_not_nil session.session_notes_updated_at
  end

  test "should clear session notes when blank" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", session_notes: "Old notes", session_notes_updated_at: Time.current)

    patch update_notes_session_url(session), params: { session_notes: "" }, as: :json

    assert_response :success
    session.reload
    assert_nil session.session_notes
    assert_nil session.session_notes_updated_at
  end

  test "should reject session notes that are too long" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")

    patch update_notes_session_url(session), params: { session_notes: "a" * 50_001 }, as: :json

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_includes json_response["error"], "too long"
  end

  test "should route to update_notes" do
    assert_routing(
      { method: :patch, path: "/sessions/1/update_notes" },
      { controller: "sessions", action: "update_notes", id: "1" }
    )
  end

  # Test refresh action
  test "should refresh transcript from filesystem" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    clone_path = "/fake/clone/path"
    session.update!(metadata: { "clone_path" => clone_path })

    transcript_content = '{"role":"user","content":"Test message"}' + "\n"
    fake_transcript_file = "/fake/.claude/projects/-fake-clone-path/test-session.jsonl"

    # Stub filesystem operations
    Dir.expects(:exist?).returns(true).at_least_once
    Dir.expects(:glob).returns([ fake_transcript_file ]).at_least_once
    File.expects(:mtime).returns(Time.current).at_least_once
    File.expects(:read).returns(transcript_content).at_least_once

    post refresh_session_url(session)
    assert_redirected_to session_path(session)
    assert_match /refreshed successfully/, flash[:notice]

    session.reload
    assert_equal transcript_content, session.transcript
    assert session.logs.where("content LIKE ?", "Transcript refreshed manually from filesystem%").exists?
    # Verify broadcast_message_count is updated to prevent duplicates
    assert_equal 1, session.metadata["broadcast_message_count"]
  end

  test "touch_activity stamps last_user_activity_at and returns 204" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    # Make the session look stale so PollBackoff is on the slow (24h) cadence.
    session.update!(metadata: { "last_user_activity_at" => 25.hours.ago.iso8601 })
    assert_equal 24.hours.to_i, PollBackoff.poll_interval(session, base_interval: 30)

    post touch_activity_session_url(session)

    assert_response :no_content
    session.reload
    # Activity advanced to ~now, so the backoff resets to the fast cadence (0 = every tick).
    assert_operator session.last_user_activity_at, :>, 1.minute.ago
    assert_equal 0, PollBackoff.poll_interval(session, base_interval: 30)
    assert PollBackoff.should_poll?(session, job_key: "pr_status", base_interval: 30)
  end

  test "refresh stamps last_user_activity_at to reset poll backoff" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    session.update!(metadata: { "clone_path" => "/fake/clone/path", "last_user_activity_at" => 25.hours.ago.iso8601 })

    Dir.expects(:exist?).returns(true).at_least_once
    Dir.expects(:glob).returns([]).at_least_once

    post refresh_session_url(session)

    session.reload
    assert_operator session.last_user_activity_at, :>, 1.minute.ago
    assert_equal 0, PollBackoff.poll_interval(session, base_interval: 30)
  end

  test "restart stamps last_user_activity_at to reset poll backoff" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )
    clone_path = Rails.root.join("tmp", "test_clone_restart_reset_#{session.id}")
    FileUtils.mkdir_p(clone_path)
    session.update!(metadata: {
      "clone_path" => clone_path.to_s,
      "working_directory" => clone_path.to_s,
      "last_user_activity_at" => 25.hours.ago.iso8601
    })
    assert_equal 24.hours.to_i, PollBackoff.poll_interval(session, base_interval: 30)

    post restart_session_url(session)

    session.reload
    assert_operator session.last_user_activity_at, :>, 1.minute.ago
    assert_equal 0, PollBackoff.poll_interval(session, base_interval: 30)
  ensure
    FileUtils.rm_rf(clone_path) if defined?(clone_path) && clone_path
  end

  test "fork stamps last_user_activity_at to reset poll backoff" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    session.update!(metadata: { "last_user_activity_at" => 25.hours.ago.iso8601 })
    assert_equal 24.hours.to_i, PollBackoff.poll_interval(session, base_interval: 30)

    # The reset rides along with the fork interaction; it is stamped before the
    # message_index validation, so even a no-op fork resets the cadence.
    post fork_session_url(session)

    session.reload
    assert_operator session.last_user_activity_at, :>, 1.minute.ago
    assert_equal 0, PollBackoff.poll_interval(session, base_interval: 30)
  end

  test "should handle missing transcript files on refresh" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    clone_path = "/fake/clone/path"
    session.update!(metadata: { "clone_path" => clone_path })

    # Stub to return empty array (no transcript files)
    Dir.expects(:exist?).returns(true).at_least_once
    Dir.expects(:glob).returns([]).at_least_once

    post refresh_session_url(session)
    assert_redirected_to session_path(session)
    assert_match /No transcript files found/, flash[:alert]
  end

  test "should handle non-existent transcript directory on refresh" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    clone_path = "/fake/clone/path"
    session.update!(metadata: { "clone_path" => clone_path })

    # Stub Dir.exist? to return false, simulating non-existent directory
    Dir.expects(:exist?).returns(false).at_least_once

    post refresh_session_url(session)
    assert_redirected_to session_path(session)
    assert_match /No transcript files found/, flash[:alert]
  end

  test "should handle missing clone_path on refresh" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    session.update!(metadata: {})

    post refresh_session_url(session)
    assert_redirected_to session_path(session)
    assert_match /No clone path found/, flash[:alert]
  end

  test "should sanitize path with dots and underscores on refresh" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    # Use a path with dots and underscores like real clone paths
    working_directory = "/Users/admin/.zimmer/clones/pulsemcp-main-1764273034-168756be"
    session.update!(metadata: { "working_directory" => working_directory })

    # Expected sanitized path: all '/', '.', and '_' replaced with '-'
    expected_sanitized = "-Users-admin--zimmer-clones-pulsemcp-main-1764273034-168756be"
    expected_transcript_dir = File.join(File.expand_path("~"), ".claude", "projects", expected_sanitized)

    transcript_content = '{"role":"user","content":"Test message"}' + "\n"
    fake_transcript_file = File.join(expected_transcript_dir, "test-session.jsonl")

    # Stub filesystem operations with the correctly sanitized path
    Dir.expects(:exist?).with(expected_transcript_dir).returns(true).at_least_once
    Dir.expects(:glob).with(File.join(expected_transcript_dir, "*.jsonl")).returns([ fake_transcript_file ]).at_least_once
    File.expects(:mtime).returns(Time.current).at_least_once
    File.expects(:read).returns(transcript_content).at_least_once

    post refresh_session_url(session)
    assert_redirected_to session_path(session)
    assert_match /refreshed successfully/, flash[:notice]

    session.reload
    assert_equal transcript_content, session.transcript
  end

  test "should resume failed session with automated recovery prompt" do
    # Create a failed session with required metadata
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    # Set up working directory
    clone_path = Rails.root.join("tmp", "test_clone_resume_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s
      }
    )

    # Mock AgentSessionJob and verify arguments
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post refresh_session_url(session)
    end

    assert_redirected_to session_path(session)
    assert_match /Attempting to resume failed session/, flash[:notice]

    session.reload
    assert_equal "running", session.status
    # Note: running_job_id is set by the job itself when it starts executing,
    # not immediately when enqueued, so we don't test for it here

    # Verify logs were created
    assert session.logs.where("content LIKE ?", "%Attempting to resume failed session%").exists?
    assert session.logs.where("content LIKE ?", "%Resume command initiated%").exists?

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  test "should not resume failed session without session_id" do
    # Create a failed session without session_id
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed
    )

    clone_path = Rails.root.join("tmp", "test_clone_no_session_id_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s
      }
    )

    # Should fall back to regular refresh behavior
    post refresh_session_url(session)

    session.reload
    assert_equal "failed", session.status  # Should remain failed

    # Verify warning log was created
    assert session.logs.where("content LIKE ?", "%Cannot resume failed session: no session_id found%").exists?

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  test "should not resume failed session without working directory" do
    # Create a failed session without working directory
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    # Don't set working_directory in metadata
    session.update!(metadata: {})

    # Should fall back to regular refresh behavior
    post refresh_session_url(session)

    session.reload
    assert_equal "failed", session.status  # Should remain failed

    # Verify warning log was created
    assert session.logs.where("content LIKE ?", "%Cannot resume failed session%").exists?
    assert session.logs.where("content LIKE ?", "%working directory not found%").exists?
  end

  test "should not resume failed session with non-existent working directory" do
    # Create a failed session with non-existent directory
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    session.update!(
      metadata: {
        "working_directory" => "/non/existent/path/#{SecureRandom.hex}"
      }
    )

    post refresh_session_url(session)

    session.reload
    assert_equal "failed", session.status
    assert session.logs.where("content LIKE ?", "%Cannot resume failed session%").exists?
    assert session.logs.where("content LIKE ?", "%working directory not found%").exists?
  end

  test "should not resume failed session with still running process" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    clone_path = Rails.root.join("tmp", "test_clone_running_process_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    # Use current process PID (which is definitely running)
    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "process_pid" => Process.pid.to_s
      }
    )

    post refresh_session_url(session)

    session.reload
    assert_equal "failed", session.status
    assert session.logs.where("content LIKE ?", "%Cannot resume: process%still running%").exists?

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  test "should prevent rapid resume attempts" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    clone_path = Rails.root.join("tmp", "test_clone_rate_limit_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s
      }
    )

    # First attempt should succeed
    assert_enqueued_with(job: AgentSessionJob) do
      post refresh_session_url(session)
    end

    session.reload
    assert_equal "running", session.status

    # Reset to failed for second attempt
    session.update!(status: :failed)

    # Second attempt within 1 minute should be blocked
    assert_no_enqueued_jobs do
      post refresh_session_url(session)
    end

    session.reload
    assert_equal "failed", session.status
    assert session.logs.where("content LIKE ?", "%Resume attempted too recently%").exists?

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  test "refresh should clear runtime_started for pre-prompt failures via resume_failed_session" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    clone_path = Rails.root.join("tmp", "test_clone_preprompt_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "failure_reason" => "mcp_connection_failed",
        "runtime_started" => true
      }
    )

    assert_enqueued_with(job: AgentSessionJob) do
      post refresh_session_url(session)
    end

    session.reload
    assert_equal "running", session.status
    # runtime_started should be cleared for pre-prompt failures
    assert_nil session.metadata["runtime_started"]
    # Other metadata should be preserved
    assert_equal clone_path.to_s, session.metadata["working_directory"]

    FileUtils.rm_rf(clone_path)
  end

  test "refresh should preserve runtime_started for post-prompt failures via resume_failed_session" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    clone_path = Rails.root.join("tmp", "test_clone_postprompt_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "failure_reason" => "process_failed",
        "runtime_started" => true
      }
    )

    assert_enqueued_with(job: AgentSessionJob) do
      post refresh_session_url(session)
    end

    session.reload
    assert_equal "running", session.status
    # runtime_started should be preserved for post-prompt failures
    assert_equal true, session.metadata["runtime_started"]

    FileUtils.rm_rf(clone_path)
  end

  test "should not resume non-failed sessions" do
    # Create a running session
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :running,
      session_id: SecureRandom.uuid
    )

    clone_path = "/fake/clone/path"
    session.update!(
      metadata: {
        "clone_path" => clone_path,
        "working_directory" => clone_path
      }
    )

    transcript_content = '{"role":"user","content":"Test message"}' + "\n"
    fake_transcript_file = "/fake/.claude/projects/-fake-clone-path/test-session.jsonl"

    Dir.expects(:exist?).returns(true).at_least_once
    Dir.expects(:glob).returns([ fake_transcript_file ]).at_least_once
    File.expects(:mtime).returns(Time.current).at_least_once
    File.expects(:read).returns(transcript_content).at_least_once

    # Should not enqueue resume job
    assert_no_enqueued_jobs do
      post refresh_session_url(session)
    end

    session.reload
    assert_equal "running", session.status  # Should remain running

    # Should not have resume logs
    refute session.logs.where("content LIKE ?", "%Attempting to resume failed session%").exists?
  end

  test "should restore job when session is running but has no active job" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", status: :running)

    # Create a fake process that appears to be running
    fake_pid = Process.pid # Use current process PID for testing
    clone_path = "/fake/clone/path"
    session.update!(
      running_job_id: "fake-job-id-that-doesnt-exist",
      metadata: {
        "process_pid" => fake_pid,
        "clone_path" => clone_path,
        "working_directory" => clone_path
      }
    )

    transcript_content = '{"role":"user","content":"Test message"}' + "\n"
    fake_transcript_file = "/fake/.claude/projects/-fake-clone-path/test-session.jsonl"

    Dir.expects(:exist?).returns(true).at_least_once
    Dir.expects(:glob).returns([ fake_transcript_file ]).at_least_once
    File.expects(:mtime).returns(Time.current).at_least_once
    File.expects(:read).returns(transcript_content).at_least_once

    # Enqueue the restore job
    # Note: nil is required for follow_up_prompt to ensure resume_monitoring is passed as keyword arg.
    # monitor_pid pins the job to the process this restore was decided about (zimmer#489).
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, nil, { resume_monitoring: true, monitor_pid: fake_pid } ]) do
      post refresh_session_url(session)
    end

    # Verify log was created
    session.reload
    assert session.logs.where("content LIKE ?", "Restoring monitoring job for process%").exists?
    assert session.logs.where("content LIKE ?", "Monitoring job enqueued%").exists?
  end

  test "should not restore job when session has active job" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", status: :running)

    # Create a real job in the queue
    job = AgentSessionJob.enqueue_new_session(session.id)
    session.update!(running_job_id: job.job_id)

    clone_path = "/fake/clone/path"
    session.update!(metadata: { "clone_path" => clone_path })

    transcript_content = '{"role":"user","content":"Test message"}' + "\n"
    fake_transcript_file = "/fake/.claude/projects/-fake-clone-path/test-session.jsonl"

    Dir.expects(:exist?).returns(true).at_least_once
    Dir.expects(:glob).returns([ fake_transcript_file ]).at_least_once
    File.expects(:mtime).returns(Time.current).at_least_once
    File.expects(:read).returns(transcript_content).at_least_once

    # Refresh should succeed but not enqueue a restore job
    post refresh_session_url(session)

    # Verify no restore log was created
    session.reload
    refute session.logs.where("content LIKE ?", "Restoring monitoring job for process%").exists?
  end

  test "should enqueue monitoring job when restoring job for session with process" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", status: :running)
    session.update!(session_id: "test-session-id")

    # Use a fake PID - restore_agent_session_job no longer checks PIDs locally
    # because in multi-container deployments, the web container can't see worker PIDs.
    # Instead, it always enqueues a monitoring job that runs in the correct container.
    fake_pid = 999999999
    clone_path = Rails.root.join("tmp", "test_clone_#{SecureRandom.hex(4)}").to_s
    FileUtils.mkdir_p(clone_path)
    session.update!(
      running_job_id: "fake-job-id-that-doesnt-exist",
      metadata: {
        "process_pid" => fake_pid,
        "clone_path" => clone_path,
        "working_directory" => clone_path
      }
    )

    transcript_content = '{"role":"user","content":"Test message"}' + "\n"
    fake_transcript_file = "/fake/.claude/projects/-fake-clone-path/test-session.jsonl"

    Dir.expects(:exist?).returns(true).at_least_once
    Dir.expects(:glob).returns([ fake_transcript_file ]).at_least_once
    File.expects(:mtime).returns(Time.current).at_least_once
    File.expects(:read).returns(transcript_content).at_least_once

    post refresh_session_url(session)

    # Verify a monitoring job was enqueued (the job will check process status in the correct container)
    session.reload
    assert session.logs.where("content LIKE ?", "%Restoring monitoring job for process%").exists?
    assert session.logs.where("content LIKE ?", "%Monitoring job enqueued%").exists?
  ensure
    FileUtils.rm_rf(clone_path) if clone_path && Dir.exist?(clone_path)
  end

  test "should log warning when restoring job for session without process_pid" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", status: :running)
    clone_path = "/fake/clone/path"
    session.update!(
      running_job_id: "fake-job-id-that-doesnt-exist",
      metadata: { "clone_path" => clone_path, "working_directory" => clone_path }
      # Note: no "process_pid" key
    )

    transcript_content = '{"role":"user","content":"Test message"}' + "\n"
    fake_transcript_file = "/fake/.claude/projects/-fake-clone-path/test-session.jsonl"

    Dir.expects(:exist?).returns(true).at_least_once
    Dir.expects(:glob).returns([ fake_transcript_file ]).at_least_once
    File.expects(:mtime).returns(Time.current).at_least_once
    File.expects(:read).returns(transcript_content).at_least_once

    post refresh_session_url(session)

    session.reload
    assert session.logs.where("content LIKE ?", "%no process_pid%").exists?
    refute session.logs.where("content LIKE ?", "%Monitoring job enqueued%").exists?
  end

  # Test pause action
  test "should pause running session" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", status: :running)
    # Use a fake PID that won't exist
    fake_pid = 999999
    session.update!(metadata: { "process_pid" => fake_pid })

    post pause_session_url(session)

    session.reload
    assert_equal "needs_input", session.status
    assert_redirected_to session_path(session)
    assert_match /Session paused successfully/, flash[:notice]
  end

  test "pause stamps last_user_activity_at to reset poll backoff" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", status: :running)
    session.update!(metadata: { "process_pid" => 999999, "last_user_activity_at" => 25.hours.ago.iso8601 })

    post pause_session_url(session)

    session.reload
    assert_operator session.last_user_activity_at, :>, 1.minute.ago
    assert_equal 0, PollBackoff.poll_interval(session, base_interval: 30)
  end

  test "should not pause non-running session" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", status: :needs_input)

    post pause_session_url(session)

    assert_redirected_to session_path(session)
    assert_match /Cannot pause session that is not running/, flash[:alert]
  end

  test "should handle pause with no process" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", status: :running)
    # Don't set process_pid in metadata

    post pause_session_url(session)

    assert_redirected_to session_path(session)
    assert_match /Cannot pause session: no process found/, flash[:alert]
  end

  test "should create log entries on pause" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", status: :running)
    # Use a fake PID that won't exist
    fake_pid = 999999
    session.update!(metadata: { "process_pid" => fake_pid })

    initial_log_count = session.logs.count

    post pause_session_url(session)

    session.reload
    # Should have created at least 3 logs: pausing message, terminated message, paused successfully message
    assert session.logs.count >= initial_log_count + 2
    assert session.logs.where("content LIKE ?", "%Pausing Claude CLI session%").exists?
    assert session.logs.where("content LIKE ?", "%Session paused successfully%").exists?
  end

  test "should succeed pause even when EPERM is raised from process kill" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", status: :running)
    fake_pid = 999999
    session.update!(metadata: { "process_pid" => fake_pid })

    # Mock Process.kill to raise EPERM (permission denied)
    # This simulates the case where the process belongs to another user
    Process.stubs(:kill).raises(Errno::EPERM)

    post pause_session_url(session)

    session.reload
    # Session should still be paused successfully
    assert_equal "needs_input", session.status
    assert_redirected_to session_path(session)
    # Should show success message, not error
    assert_match /Session paused successfully/, flash[:notice]
    assert_nil flash[:alert]
  end

  # Test restart action
  test "should restart failed session with automated recovery prompt" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    # Set up working directory
    clone_path = Rails.root.join("tmp", "test_clone_restart_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s
      }
    )

    # Mock AgentSessionJob and verify arguments
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_session_url(session)
    end

    assert_redirected_to session_path(session)
    assert_match /Attempting to restart failed session/, flash[:notice]

    session.reload
    assert_equal "running", session.status

    # Verify logs were created
    assert session.logs.where("content LIKE ?", "%Restarting failed session: sending automated recovery prompt%").exists?
    assert session.logs.where("content LIKE ?", "%Session resumed%").exists?

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  test "should restart with initial prompt when session failed before initial prompt was processed" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Please fix the authentication bug in login.rb",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    clone_path = Rails.root.join("tmp", "test_clone_initial_prompt_restart_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "failure_reason" => "mcp_connection_failed",
        "mcp_failed_servers" => [ { "name" => "test-server", "status" => "failed" } ],
        "runtime_started" => true
      }
    )

    # Should enqueue job with the ORIGINAL prompt, not the system recovery prompt
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, "Please fix the authentication bug in login.rb" ]) do
      post restart_session_url(session)
    end

    assert_redirected_to session_path(session)
    assert_match /Attempting to restart failed session/, flash[:notice]

    session.reload
    assert_equal "running", session.status

    # Verify logs indicate re-sending initial prompt
    assert session.logs.where("content LIKE ?", "%re-sending initial prompt%").exists?
    assert session.logs.where("content LIKE ?", "%Session resumed%").exists?

    # Verify stale metadata was cleared
    assert_nil session.metadata["failure_reason"]
    assert_nil session.metadata["mcp_failed_servers"]

    # runtime_started must be cleared for pre-prompt failures so the restart
    # job uses --session-id (with --mcp-config) instead of --resume
    assert_nil session.metadata["runtime_started"]

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  test "should restart with recovery prompt when session failed after initial prompt was processed" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Please fix the authentication bug in login.rb",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    clone_path = Rails.root.join("tmp", "test_clone_recovery_restart_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "failure_reason" => "process_failed",
        "runtime_started" => true
      }
    )

    # Should enqueue job with the SYSTEM_RECOVERY prompt (not the initial prompt)
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_session_url(session)
    end

    assert_redirected_to session_path(session)

    session.reload
    assert_equal "running", session.status

    # Verify logs indicate automated recovery prompt
    assert session.logs.where("content LIKE ?", "%sending automated recovery prompt%").exists?

    # runtime_started must be PRESERVED for post-prompt failures so the
    # restart job uses --resume to continue the existing conversation
    assert_equal true, session.metadata["runtime_started"]

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  test "should restart with initial prompt for oauth_required failure" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Deploy the new feature",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    clone_path = Rails.root.join("tmp", "test_clone_oauth_restart_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "failure_reason" => "oauth_required"
      }
    )

    # Should enqueue job with the ORIGINAL prompt since OAuth failure is pre-prompt
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, "Deploy the new feature" ]) do
      post restart_session_url(session)
    end

    session.reload
    assert_equal "running", session.status
    assert session.logs.where("content LIKE ?", "%re-sending initial prompt%").exists?

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  test "should restart with recovery prompt when pre-prompt failure but prompt is blank" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: nil,
      status: :failed,
      session_id: SecureRandom.uuid
    )

    clone_path = Rails.root.join("tmp", "test_clone_blank_prompt_restart_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "failure_reason" => "mcp_connection_failed"
      }
    )

    # Should fall back to SYSTEM_RECOVERY since there's no initial prompt to re-send
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_session_url(session)
    end

    session.reload
    assert_equal "running", session.status
    assert session.logs.where("content LIKE ?", "%sending automated recovery prompt%").exists?

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  test "should not restart non-failed session" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", status: :running)

    post restart_session_url(session)

    assert_redirected_to session_path(session)
    assert_match /Cannot restart session that is not failed/, flash[:alert]
  end

  test "should reconnect to running process on restart" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    # Use current process PID (which is definitely running)
    clone_path = Rails.root.join("tmp", "test_clone_reconnect_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "process_pid" => Process.pid
      }
    )

    # Should enqueue resume_monitoring job since process is running
    # Note: nil is required for follow_up_prompt to ensure resume_monitoring is passed as keyword arg.
    # monitor_pid pins the job to the process this reconnect was decided about (zimmer#489).
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, nil, { resume_monitoring: true, monitor_pid: Process.pid } ]) do
      post restart_session_url(session)
    end

    assert_redirected_to session_path(session)
    assert_match /Reconnected to running process/, flash[:notice]

    session.reload
    assert_equal "running", session.status
    assert session.logs.where("content LIKE ?", "%reconnecting to running process%").exists?

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  test "should restart with automated recovery prompt when process is not running" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    # Use a fake PID that definitely doesn't exist
    clone_path = Rails.root.join("tmp", "test_clone_dead_process_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "process_pid" => 999999999
      }
    )

    # Should enqueue automated recovery prompt job since process is dead
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_session_url(session)
    end

    assert_redirected_to session_path(session)
    assert_match /Attempting to restart failed session/, flash[:notice]

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  # The inverse guard for zimmer#557. A transcript with no session_id is a
  # session that HAS work — that is what a fresh-start recovery leaves behind on
  # a runtime that mints its own conversation id — so the refusal stays loud
  # rather than being rerouted into a fresh start that would discard it.
  test "should not restart failed session with a transcript but no session_id" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      transcript: %({"type":"user","message":{"role":"user","content":"Hi"}}\n)
    )

    clone_path = Rails.root.join("tmp", "test_clone_no_session_id_restart_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s
      }
    )

    assert_no_enqueued_jobs only: AgentSessionJob do
      post restart_session_url(session)
    end

    session.reload
    assert_equal "failed", session.status
    assert session.logs.where("content LIKE ?", "%Cannot restart session: no session_id found%").exists?
    # Flash now includes the specific error message
    assert_match /Cannot restart session: no session_id found/, flash[:alert]

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  # zimmer#557: a session whose agent process never launched has no conversation
  # to prompt into, so the Restart button re-runs the full setup pipeline instead
  # of refusing with a precondition that only makes sense for a resume.
  test "should restart a failed session that never ran by starting it from scratch" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Investigate the flaky test",
      status: :failed
    )
    assert session.never_ran?

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      post restart_session_url(session)
    end

    session.reload
    assert_equal "running", session.status
    assert_equal "Investigate the flaky test", session.prompt
    assert_match /Attempting to restart failed session/, flash[:notice]
    assert session.logs.where("content LIKE ?", "%Restarting session from scratch%").exists?
  end

  test "should restart failed session without working directory by letting job handle clone recreation" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    session.update!(metadata: {})

    # Should succeed — the job handles clone recreation when working_directory is missing
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_session_url(session)
    end

    session.reload
    assert_equal "running", session.status
    assert_match /Attempting to restart failed session/, flash[:notice]
  end

  # Tests for restart_from_scratch path (sessions that failed before setup completed)

  test "should restart from scratch when git clone failed and no setup artifacts exist" do
    session = Session.create!(
      prompt: "Fix the authentication bug",
      status: :failed,
      git_root: "https://github.com/test/repo.git"
    )

    # Simulate git_clone_failed: failure_reason set, but no session_id, clone_path, or working_directory
    session.update!(
      metadata: {
        "failure_reason" => "git_clone_failed"
      }
    )

    # Should enqueue as a NEW session (not follow-up) to re-run the full setup pipeline
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      post restart_session_url(session)
    end

    assert_redirected_to session_path(session)
    assert_match /Attempting to restart failed session/, flash[:notice]

    session.reload
    assert_equal "running", session.status

    # session_id should be nil (will be regenerated by the job during setup)
    assert_nil session.session_id

    # Verify logs indicate restart from scratch
    assert session.logs.where("content LIKE ?", "%Restarting session from scratch%").exists?
    assert session.logs.where("content LIKE ?", "%full setup will be re-attempted%").exists?

    # A session with nothing stored says nothing about what it carries.
    assert_not session.logs.where("content LIKE ?", "%carrying%").exists?

    # Verify stale metadata was cleared
    assert_nil session.metadata["failure_reason"]
  end

  test "should restart from scratch when clone_validation_failed and setup incomplete" do
    session = Session.create!(
      prompt: "Deploy the feature",
      status: :failed,
      git_root: "https://github.com/test/repo.git"
    )

    session.update!(
      metadata: {
        "failure_reason" => "clone_validation_failed"
      }
    )

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      post restart_session_url(session)
    end

    session.reload
    assert_equal "running", session.status
    assert_nil session.session_id
    assert session.logs.where("content LIKE ?", "%Restarting session from scratch%").exists?
  end

  test "should restart from scratch clearing stale setup artifacts when no setup artifacts exist" do
    session = Session.create!(
      prompt: "Fix the bug",
      status: :failed,
      git_root: "https://github.com/test/repo.git"
    )

    # Simulate git_clone_failed with NO setup artifacts (session_id, clone_path never set).
    # Also include stale retry metadata that should be cleared.
    session.update!(
      metadata: {
        "failure_reason" => "git_clone_failed",
        "sigterm_retry_count" => 2,
        "api_error_retry_count" => 1
      }
    )

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      post restart_session_url(session)
    end

    session.reload
    assert_equal "running", session.status

    # session_id should be nil (will be regenerated by the job during setup)
    assert_nil session.session_id

    # Stale retry metadata should be cleared
    assert_nil session.metadata["sigterm_retry_count"]
    assert_nil session.metadata["api_error_retry_count"]
    assert_nil session.metadata["failure_reason"]
  end

  # The backoff ladder on a held spot session can only know a person asked for this
  # session if the caller says so — a restart re-enters the gate looking exactly
  # like the scheduled re-check (no prompt, no resume flag). Saying so is dropping
  # the hold metadata here. Without it, Restart on a session sitting at 40 minutes
  # would push it to an hour, the opposite of what was asked for.
  test "restart from scratch clears the spot-hold backoff ladder" do
    session = Session.create!(
      prompt: "Fix the bug",
      status: :failed,
      git_root: "https://github.com/test/repo.git"
    )
    session.update!(
      metadata: {
        "failure_reason" => "git_clone_failed",
        SpotSessionHold::HELD_AT => 20.minutes.ago.iso8601,
        SpotSessionHold::HELD_REASON => "at_utilization_limit",
        SpotSessionHold::HELD_DETAIL => "Holding spot sessions: the 5-hour window is at its target.",
        SpotSessionHold::HELD_RETRY_AT => 40.minutes.from_now.iso8601,
        SpotSessionHold::HELD_COUNT => 4
      }
    )

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      post restart_session_url(session)
    end

    session.reload
    SpotSessionHold::METADATA_KEYS.each do |key|
      assert_nil session.metadata[key], "#{key} must not survive a restart — it is the backoff ladder"
    end
  end

  # --- restart from scratch carries the first turn's attachments ---------------
  #
  # AgentSessionJob receives images and files ONLY as job arguments, so a restart
  # that enqueued bare re-ran the original prompt with the screenshot silently
  # missing (#746). The bytes were on the durable volume the whole time.

  test "restart from scratch enqueues the replacement turn carrying the stored attachments" do
    session = Session.create!(
      prompt: "here is the screenshot, fix this",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      metadata: { "failure_reason" => "git_clone_failed" }
    )
    image = store_image_for(session)
    file = store_file_for(session, filename: "notes.txt", content: "read me")

    post restart_session_url(session)

    assert_enqueued_with(
      job: AgentSessionJob,
      args: [
        session.id, nil,
        {
          images: [ { path: image[:path], media_type: "image/png" } ],
          files: [ { path: file[:path], original_filename: "notes.txt", size: "read me".bytesize } ]
        }
      ]
    )
    assert session.logs.where("content LIKE ?", "%carrying 1 image and 1 file%").exists?
  end

  # This path is taken when something has ALREADY gone wrong. A storage tree that
  # cannot be read must cost the attachments, never the restart.
  test "restart from scratch still restarts when the attachment storage cannot be read" do
    session = Session.create!(
      prompt: "here is the screenshot, fix this",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      metadata: { "failure_reason" => "git_clone_failed" }
    )
    store_image_for(session)

    ImageStorageService.stub(:stored_for, ->(*) { raise Errno::EACCES, "storage" }) do
      assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
        post restart_session_url(session)
      end
    end

    assert_redirected_to session_path(session)
    assert_equal "running", session.reload.status
  end

  # The banner is the only place a person sees WHY a session is sitting in
  # `waiting`, and a hold on a wake reads differently from a hold at the starting
  # line: this session has run before, and the prompt it was woken for is queued.
  test "the spot hold banner says a NEXT TURN is held when the gate refused a wake" do
    session = Session.create!(
      prompt: "Fix the bug",
      status: :waiting,
      scheduling_class: SessionGenesis::SPOT,
      git_root: "https://github.com/test/repo.git"
    )
    session.update!(metadata: {
      SpotSessionHold::HELD_AT => 2.minutes.ago.iso8601,
      SpotSessionHold::HELD_REASON => "at_utilization_limit",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5-hour window at 87% of its 65% target.",
      SpotSessionHold::HELD_RETRY_AT => 10.minutes.from_now.iso8601,
      SpotSessionHold::HELD_COUNT => 1,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_RESUME
    })

    get session_url(session)

    assert_response :success
    assert_select "[data-spot-hold-banner] h3", text: /Next turn held for quota headroom/
    assert_select "[data-spot-hold-banner]", text: /the turn it was woken for is queued/
    assert_select "[data-spot-hold-banner]", text: /Make this session priority/
  end

  test "the spot hold banner still says a session was held at the starting line" do
    session = Session.create!(
      prompt: "Fix the bug",
      status: :waiting,
      scheduling_class: SessionGenesis::SPOT,
      git_root: "https://github.com/test/repo.git"
    )
    session.update!(metadata: {
      SpotSessionHold::HELD_AT => 2.minutes.ago.iso8601,
      SpotSessionHold::HELD_REASON => "at_utilization_limit",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5-hour window at 87% of its 65% target.",
      SpotSessionHold::HELD_RETRY_AT => 10.minutes.from_now.iso8601,
      SpotSessionHold::HELD_COUNT => 1,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START
    })

    get session_url(session)

    assert_response :success
    assert_select "[data-spot-hold-banner] h3", text: /Held for quota headroom/
    assert_select "[data-spot-hold-banner]", text: /it will start on its own once the gate lets it/
  end

  # A hold record is a SNAPSHOT of what the gate said at `spot_hold_at`, and the
  # banner used to replay it as a present-tense claim with nothing to say
  # otherwise. Session 7507's page read "5 of 5 session slots taken" eleven hours
  # after the gate had gone back to `within_limits` and 1 of 5, and the only tell
  # was a "next check" time already in the past, rendered as though upcoming.
  test "the spot hold banner says how old the gate reading is" do
    session = Session.create!(
      prompt: "Fix the bug",
      status: :waiting,
      scheduling_class: SessionGenesis::SPOT,
      git_root: "https://github.com/test/repo.git"
    )
    session.update!(metadata: {
      SpotSessionHold::HELD_AT => 3.hours.ago.iso8601,
      SpotSessionHold::HELD_REASON => "fleet_at_cap",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5 of 5 session slots taken.",
      SpotSessionHold::HELD_RETRY_AT => 10.minutes.from_now.iso8601,
      SpotSessionHold::HELD_COUNT => 145,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_RESUME
    })

    get session_url(session)

    assert_response :success
    assert_select "[data-spot-hold-as-of]", text: /gate's reading about 3 hours ago/
    assert_select "[data-spot-hold-as-of]", text: /not a live one/
    assert_select "[data-spot-hold-recheck]", text: /Next check/
  end

  # A re-check due one second ago is a job that has not been picked up yet, not a
  # stalled ladder — and the page must not say otherwise while /inference, reading
  # the same predicate with the sweep's grace, counts it as fine.
  test "the spot hold banner does not call a barely-late re-check stalled" do
    session = Session.create!(
      prompt: "Fix the bug",
      status: :waiting,
      scheduling_class: SessionGenesis::SPOT,
      git_root: "https://github.com/test/repo.git"
    )
    session.update!(metadata: {
      SpotSessionHold::HELD_AT => 1.hour.ago.iso8601,
      SpotSessionHold::HELD_REASON => "fleet_at_cap",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5 of 5 session slots taken.",
      SpotSessionHold::HELD_RETRY_AT => 30.seconds.ago.iso8601,
      SpotSessionHold::HELD_COUNT => 3,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_RESUME
    })

    get session_url(session)

    assert_response :success
    assert_select "[data-spot-hold-banner] h3", { text: /Spot hold stalled/, count: 0 }
    assert_select "[data-spot-hold-recheck]", { text: /has not fired/, count: 0 }
  end

  # An overdue re-check is not a hold, it is a stalled ladder: the session is
  # waiting on nothing until SpotHoldSweepJob puts it back. The banner must never
  # print an already-past "next check" as if it were upcoming.
  test "the spot hold banner names an overdue re-check as overdue, not as upcoming" do
    session = Session.create!(
      prompt: "Fix the bug",
      status: :waiting,
      scheduling_class: SessionGenesis::SPOT,
      git_root: "https://github.com/test/repo.git"
    )
    session.update!(metadata: {
      SpotSessionHold::HELD_AT => 11.hours.ago.iso8601,
      SpotSessionHold::HELD_REASON => "fleet_at_cap",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5 of 5 session slots taken.",
      SpotSessionHold::HELD_RETRY_AT => 10.hours.ago.iso8601,
      SpotSessionHold::HELD_COUNT => 145,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_RESUME
    })

    get session_url(session)

    assert_response :success
    assert_select "[data-spot-hold-banner] h3", text: /Spot hold stalled/
    assert_select "[data-spot-hold-recheck]", text: /re-check was due about 10 hours ago/
    assert_select "[data-spot-hold-recheck]", text: /has not fired/
    assert_select "[data-spot-hold-recheck]", text: /spot-hold sweep re-arms it/
    assert_select "[data-spot-hold-recheck]", { text: /Next check/, count: 0 }
  end

  # The same precedence `get_session` applies, on the surface a human reads. A
  # session parked for an auth outage AFTER the gate held it is waiting on the
  # account pool, and the spot box below the outage banner must not send the
  # reader back to the spot gate — nor promise a sweep that skips this session
  # (SpotSessionHold.held_sessions excludes a row that also carries a park). #642.
  test "the spot hold banner defers to a newer auth-outage park" do
    session = Session.create!(
      prompt: "Fix the bug",
      status: :waiting,
      scheduling_class: SessionGenesis::SPOT,
      git_root: "https://github.com/test/repo.git"
    )
    session.update!(metadata: {
      SpotSessionHold::HELD_AT => 2.days.ago.iso8601,
      SpotSessionHold::HELD_REASON => "at_utilization_limit",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5-hour window at 87% of its 65% target.",
      SpotSessionHold::HELD_RETRY_AT => 47.hours.ago.iso8601,
      SpotSessionHold::HELD_COUNT => 25,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START,
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => 1.day.ago.iso8601
    })

    get session_url(session)

    assert_response :success
    assert_select "[data-spot-hold-superseded]", text: /This is not why the session is waiting now/
    assert_select "[data-spot-hold-superseded]", text: /the spot-hold sweep skips a session/
    assert_select "[data-spot-hold-recheck]", false,
                  "the sweep this sentence promises skips a session that also carries a park"
  end

  # A demoted hold loses on the carve-out, NOT on age — it can be the newer of the
  # two records — so the banner must not tell a human the park "was recorded later"
  # when it was recorded two hours earlier.
  test "the spot hold banner does not claim a demoted hold is the older record" do
    session = Session.create!(
      prompt: "Fix the bug",
      status: :waiting,
      scheduling_class: SessionGenesis::SPOT,
      git_root: "https://github.com/test/repo.git"
    )
    session.update!(metadata: {
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => 5.hours.ago.iso8601,
      SpotSessionHold::HELD_AT => 3.hours.ago.iso8601,
      SpotSessionHold::HELD_REASON => "at_utilization_limit",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5-hour window at 87% of its 65% target.",
      SpotSessionHold::HELD_RETRY_AT => 2.hours.ago.iso8601,
      SpotSessionHold::HELD_COUNT => 4,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START
    })

    get session_url(session)

    assert_response :success
    assert_select "[data-spot-hold-superseded]", text: /nothing is coming to re-arm this hold/
    assert_select "[data-spot-hold-superseded]", { text: /was recorded later/, count: 0 }
  end

  # ...and it defers only while the park is the newer record. A hold taken since
  # is a live hold, and the spot gate really is what this session is waiting on.
  test "the spot hold banner keeps its re-check when the hold is newer than the park" do
    session = Session.create!(
      prompt: "Fix the bug",
      status: :waiting,
      scheduling_class: SessionGenesis::SPOT,
      git_root: "https://github.com/test/repo.git"
    )
    session.update!(metadata: {
      "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED,
      "auth_outage_parked_at" => 1.day.ago.iso8601,
      SpotSessionHold::HELD_AT => 2.minutes.ago.iso8601,
      SpotSessionHold::HELD_REASON => "fleet_at_cap",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5 of 5 session slots taken.",
      SpotSessionHold::HELD_RETRY_AT => 10.minutes.from_now.iso8601,
      SpotSessionHold::HELD_COUNT => 1,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START
    })

    get session_url(session)

    assert_response :success
    assert_select "[data-spot-hold-superseded]", false
    assert_select "[data-spot-hold-recheck]", text: /Next check/
  end

  # One box, two spot records: the banner used to render whichever the HOLD keys
  # described, whatever the pause beside it said. Ranked now, like everything else.
  test "the spot hold banner renders the newer of a hold and a ceiling pause" do
    session = Session.create!(
      prompt: "Fix the bug",
      status: :waiting,
      scheduling_class: SessionGenesis::SPOT,
      git_root: "https://github.com/test/repo.git"
    )
    session.update!(metadata: {
      SpotSessionHold::HELD_AT => 3.hours.ago.iso8601,
      SpotSessionHold::HELD_REASON => "fleet_at_cap",
      SpotSessionHold::HELD_DETAIL => "Holding spot sessions: 5 of 5 session slots taken.",
      SpotSessionHold::HELD_RETRY_AT => 10.minutes.from_now.iso8601,
      SpotSessionHold::HELD_COUNT => 3,
      SpotSessionHold::HELD_TURN => SpotSessionHold::TURN_START,
      SpotSessionPause::PAUSED_AT => 2.minutes.ago.iso8601,
      SpotSessionPause::PAUSED_REASON => "at_utilization_limit",
      SpotSessionPause::PAUSED_DETAIL => "Pausing spot sessions: the 5-hour window's spot budget is spent.",
      SpotSessionPause::PAUSED_COUNT => 1
    })

    get session_url(session)

    assert_response :success
    assert_select "[data-spot-hold-banner] h3", text: /Paused mid-run for quota headroom/
    assert_select "[data-spot-hold-banner]", text: /spot budget is spent/
  end

  test "should use normal restart for pre-prompt failure with complete setup artifacts even if clone deleted" do
    session = Session.create!(
      prompt: "Fix the bug",
      status: :failed,
      session_id: SecureRandom.uuid,
      git_root: "https://github.com/test/repo.git"
    )

    # Simulate: clone_path was stored but directory was deleted from disk.
    # Since setup artifacts exist in metadata, the normal restart path handles this —
    # the job will recreate the clone as needed.
    session.update!(
      metadata: {
        "failure_reason" => "git_clone_failed",
        "clone_path" => "/nonexistent/clone/path",
        "working_directory" => "/nonexistent/clone/path/subdir",
        "runtime_started" => true
      }
    )

    # Should use enqueue_with_prompt (normal restart) since setup artifacts exist
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, "Fix the bug" ]) do
      post restart_session_url(session)
    end

    session.reload
    assert_equal "running", session.status

    # session_id should be PRESERVED for normal restart
    assert_not_nil session.session_id

    # clone_path should be preserved — the job handles stale clone recreation
    assert_equal "/nonexistent/clone/path", session.metadata["clone_path"]

    # runtime_started should be cleared for pre-prompt failures
    assert_nil session.metadata["runtime_started"]

    # failure_reason should be cleared (it's in STALE_RETRY_METADATA_KEYS)
    assert_nil session.metadata["failure_reason"]
  end

  test "should not restart from scratch without git_root" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      metadata: { "failure_reason" => "git_clone_failed" }
    )
    # Clear git_root to simulate a session missing it (skip validations)
    session.update_column(:git_root, nil)
    session.reload

    post restart_session_url(session)

    session.reload
    assert_equal "failed", session.status
    assert session.logs.where("content LIKE ?", "%cannot restart from scratch: no git_root configured%").exists?
    assert_match /Cannot restart session/, flash[:alert]
  end

  test "should use normal restart path when pre-prompt failure has complete setup artifacts" do
    session = Session.create!(
      prompt: "Fix the auth bug",
      status: :failed,
      session_id: SecureRandom.uuid,
      git_root: "https://github.com/test/repo.git"
    )

    clone_path = Rails.root.join("tmp", "test_clone_normal_restart_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "failure_reason" => "spawn_failed",
        "runtime_started" => true
      }
    )

    # Should use enqueue_with_prompt (normal restart), not enqueue_new_session
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, "Fix the auth bug" ]) do
      post restart_session_url(session)
    end

    session.reload
    assert_equal "running", session.status

    # session_id should be PRESERVED (not cleared) for normal restart
    assert_not_nil session.session_id

    # Verify logs indicate normal restart, not from-scratch
    assert session.logs.where("content LIKE ?", "%re-sending initial prompt%").exists?
    refute session.logs.where("content LIKE ?", "%Restarting session from scratch%").exists?

    FileUtils.rm_rf(clone_path)
  end

  test "should route to restart" do
    assert_routing(
      { method: :post, path: "/sessions/1/restart" },
      { controller: "sessions", action: "restart", id: "1" }
    )
  end

  test "should reset sigterm retry metadata on restart" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    # Set up working directory
    clone_path = Rails.root.join("tmp", "test_clone_sigterm_reset_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    # Set up metadata with SIGTERM retry state
    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "sigterm_retry_count" => 3,
        "sigterm_retry_timestamps" => [ "2025-11-29T18:21:47Z", "2025-11-29T18:22:09Z", "2025-11-29T18:25:40Z" ],
        "last_sigterm_at" => "2025-11-29T18:25:40Z"
      }
    )

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_session_url(session)
    end

    session.reload
    # SIGTERM retry metadata should be cleared
    assert_nil session.metadata["sigterm_retry_count"]
    assert_nil session.metadata["sigterm_retry_timestamps"]
    assert_nil session.metadata["last_sigterm_at"]
    # Other metadata should be preserved
    assert_equal clone_path.to_s, session.metadata["clone_path"]
    assert_equal clone_path.to_s, session.metadata["working_directory"]

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  test "should reset context length retry metadata on restart" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    # Set up working directory
    clone_path = Rails.root.join("tmp", "test_clone_context_reset_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    # Set up metadata with context length retry state (simulating a previous context limit failure)
    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "compact_retry_count" => 2,
        "pending_compact_continuation" => true,
        "context_length_last_checked_line" => 500,
        "last_compact_at" => "2026-02-17T07:38:00Z",
        "prompt_too_long_hang_detected" => true,
        "prompt_too_long_hang_detected_at_line" => 480
      }
    )

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_session_url(session)
    end

    session.reload
    # Context length retry metadata should be cleared
    assert_nil session.metadata["compact_retry_count"]
    assert_nil session.metadata["pending_compact_continuation"]
    assert_nil session.metadata["context_length_last_checked_line"]
    assert_nil session.metadata["last_compact_at"]
    assert_nil session.metadata["prompt_too_long_hang_detected"]
    assert_nil session.metadata["prompt_too_long_hang_detected_at_line"]
    # Other metadata should be preserved
    assert_equal clone_path.to_s, session.metadata["clone_path"]
    assert_equal clone_path.to_s, session.metadata["working_directory"]

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  test "should reset transcript polling metadata on restart to prevent silent transcripts" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      session_id: SecureRandom.uuid
    )

    # Set up working directory
    clone_path = Rails.root.join("tmp", "test_clone_transcript_reset_#{session.id}")
    FileUtils.mkdir_p(clone_path)

    # Set up metadata with stale transcript polling state from a previous run.
    # This is the scenario that causes "silent transcripts" on restart:
    # broadcast_message_count is preserved from the old run (e.g., 42 messages),
    # so the poller skips all messages in the new transcript that have index < 42.
    session.update!(
      metadata: {
        "clone_path" => clone_path.to_s,
        "working_directory" => clone_path.to_s,
        "broadcast_message_count" => 42,
        "transcript_waiting_logged" => true,
        "transcript_files_waiting_logged" => true,
        "transcript_reading_started_logged" => true
      }
    )

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id, AutomatedPrompts::SYSTEM_RECOVERY ]) do
      post restart_session_url(session)
    end

    session.reload
    # Transcript polling metadata should be cleared so the poller starts fresh
    assert_nil session.metadata["broadcast_message_count"],
      "broadcast_message_count must be cleared on restart to avoid skipping new transcript messages"
    assert_nil session.metadata["transcript_waiting_logged"],
      "transcript_waiting_logged must be cleared on restart to re-emit waiting logs"
    assert_nil session.metadata["transcript_files_waiting_logged"],
      "transcript_files_waiting_logged must be cleared on restart to re-emit file waiting logs"
    assert_nil session.metadata["transcript_reading_started_logged"],
      "transcript_reading_started_logged must be cleared on restart to re-emit reading started logs"
    # Other metadata should be preserved
    assert_equal clone_path.to_s, session.metadata["clone_path"]
    assert_equal clone_path.to_s, session.metadata["working_directory"]

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  # Test refresh_all action
  test "should refresh all non-archived sessions" do
    # Archive any pre-existing (fixture) sessions so the "Refreshed N" count is a
    # deterministic function of the three sessions this test creates, not of
    # whatever else happens to be in the worker's DB.
    Session.where.not(status: :archived).update_all(status: :archived)

    session1 = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt 1", status: :running)
    session2 = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt 2", status: :waiting)
    session3 = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt 3", status: :archived)

    transcript_content1 = "{\"role\":\"user\",\"content\":\"Test message #{session1.id}\"}\n"
    transcript_content2 = "{\"role\":\"user\",\"content\":\"Test message #{session2.id}\"}\n"

    # Write REAL transcript files on disk at the location the controller computes
    # (~/.claude/projects/<sanitized clone_path>), instead of globally stubbing
    # Dir.exist?/Dir.glob/File.mtime/File.read. Those process-wide singleton mocks
    # race the suite's background threads: a concurrent File.read/Dir.glob trips
    # mocha "unexpected invocation", which (raised before the first assert) left
    # this test with 0 assertions and a spurious failure (#5). Real files exercise
    # the true filesystem path with no global monkeypatching.
    created_dirs = []
    [ [ session1, transcript_content1 ], [ session2, transcript_content2 ] ].each do |session, content|
      clone_path = File.join(Dir.tmpdir, "zimmer-refresh-all-#{session.id}-#{SecureRandom.hex(4)}")
      session.update!(metadata: { "clone_path" => clone_path })

      transcript_dir = File.join(File.expand_path("~"), ".claude", "projects", PathSanitizer.sanitize(clone_path))
      FileUtils.mkdir_p(transcript_dir)
      created_dirs << transcript_dir
      File.write(File.join(transcript_dir, "session-#{session.id}.jsonl"), content)
    end

    # Give the archived session a clone_path + on-disk transcript too, to prove it
    # is skipped because it is archived — not merely because it lacks a transcript.
    session3_clone = File.join(Dir.tmpdir, "zimmer-refresh-all-archived-#{session3.id}-#{SecureRandom.hex(4)}")
    session3.update!(metadata: { "clone_path" => session3_clone })
    session3_dir = File.join(File.expand_path("~"), ".claude", "projects", PathSanitizer.sanitize(session3_clone))
    FileUtils.mkdir_p(session3_dir)
    created_dirs << session3_dir
    File.write(File.join(session3_dir, "session-#{session3.id}.jsonl"), "{\"role\":\"user\",\"content\":\"archived\"}\n")

    post refresh_all_sessions_url
    assert_redirected_to root_path
    assert_match(/Refreshed 2 session/, flash[:notice])

    # Verify transcripts were updated for non-archived sessions
    session1.reload
    session2.reload
    session3.reload

    assert_equal transcript_content1, session1.transcript
    assert_equal transcript_content2, session2.transcript
    # Archived session should not be refreshed
    assert_nil session3.transcript

    # Verify logs were created
    assert session1.logs.where("content LIKE ?", "Transcript refreshed via bulk refresh%").exists?
    assert session2.logs.where("content LIKE ?", "Transcript refreshed via bulk refresh%").exists?
    refute session3.logs.where("content LIKE ?", "Transcript refreshed via bulk refresh%").exists?
  ensure
    created_dirs&.each { |dir| FileUtils.rm_rf(dir) }
  end

  test "should handle refresh_all with no non-archived sessions" do
    # Archive all existing sessions
    Session.where.not(status: :archived).update_all(status: :archived)

    post refresh_all_sessions_url
    assert_redirected_to root_path
    assert_match /No non-archived sessions to refresh/, flash[:notice]
  end

  test "should handle refresh_all with no transcript files" do
    # Archive all existing non-archived sessions so we only test our new one
    Session.where.not(status: :archived).each { |s| s.update!(status: :archived) }

    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", status: :running)
    clone_path = "/fake/clone/path"
    session.update!(metadata: { "clone_path" => clone_path })

    # Stub to return empty array (no transcript files)
    Dir.expects(:exist?).returns(true).at_least_once
    Dir.expects(:glob).returns([]).at_least_once

    post refresh_all_sessions_url
    assert_redirected_to root_path
    assert_match /No sessions to refresh or restart/, flash[:notice]
  end

  test "should update broadcast_message_count on refresh_all" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", status: :running)
    clone_path = "/fake/clone/path"
    session.update!(metadata: { "clone_path" => clone_path })

    transcript_content = "{\"role\":\"user\",\"content\":\"Test message\"}\n"
    fake_transcript_file = "/fake/.claude/projects/-fake-clone-path/test-session.jsonl"

    Dir.expects(:exist?).returns(true).at_least_once
    Dir.expects(:glob).returns([ fake_transcript_file ]).at_least_once
    File.expects(:mtime).returns(Time.current).at_least_once
    File.expects(:read).returns(transcript_content).at_least_once

    post refresh_all_sessions_url

    session.reload
    assert_equal 1, session.metadata["broadcast_message_count"]
  end

  # Route test for refresh_all
  test "should route to refresh_all" do
    assert_routing(
      { method: :post, path: "/sessions/refresh_all" },
      { controller: "sessions", action: "refresh_all" }
    )
  end

  # Route test for refresh_category
  test "should route to refresh_category" do
    assert_routing(
      { method: :post, path: "/sessions/refresh_category" },
      { controller: "sessions", action: "refresh_category" }
    )
  end

  # Per-category refresh restarts only the target category's failed sessions and leaves
  # sessions in other categories untouched — the core scoping guarantee of the feature.
  test "refresh_category only restarts failed sessions in the target category" do
    Session.where.not(status: :archived).update_all(status: :archived)

    target_cat = Category.create!(name: "target cat")
    other_cat = Category.create!(name: "other cat")

    target_failed = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Target failed",
      status: :failed,
      session_id: SecureRandom.uuid,
      category: target_cat,
      metadata: { "working_directory" => "/tmp/target" }
    )
    other_failed = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Other failed",
      status: :failed,
      session_id: SecureRandom.uuid,
      category: other_cat,
      metadata: { "working_directory" => "/tmp/other" }
    )

    Dir.stubs(:exist?).returns(true)

    post refresh_category_sessions_url, params: { category_id: target_cat.id }

    assert_redirected_to root_path
    assert_match /Restarted 1 failed session/, flash[:notice]
    # Target category's failed session was restarted; the other category was untouched.
    assert_equal "running", target_failed.reload.status
    assert_equal "failed", other_failed.reload.status
  end

  # The "uncategorized" sentinel targets sessions with no category_id, without touching
  # sessions that belong to a real category.
  test "refresh_category with uncategorized sentinel only restarts sessions with no category" do
    Session.where.not(status: :archived).update_all(status: :archived)

    real_cat = Category.create!(name: "real cat")

    uncategorized_failed = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Uncategorized failed",
      status: :failed,
      session_id: SecureRandom.uuid,
      category: nil,
      metadata: { "working_directory" => "/tmp/uncat" }
    )
    categorized_failed = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Categorized failed",
      status: :failed,
      session_id: SecureRandom.uuid,
      category: real_cat,
      metadata: { "working_directory" => "/tmp/cat" }
    )

    Dir.stubs(:exist?).returns(true)

    post refresh_category_sessions_url, params: { category_id: "uncategorized" }

    assert_redirected_to root_path
    assert_equal "running", uncategorized_failed.reload.status
    assert_equal "failed", categorized_failed.reload.status
  end

  # Frozen categories are a parked bucket excluded from refresh — the action refuses
  # them server-side even if a request is crafted directly.
  test "refresh_category refuses a frozen category and leaves its sessions untouched" do
    frozen_cat = Category.create!(name: "parked", is_frozen: true)
    frozen_failed = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "parked failed",
      status: :failed,
      session_id: SecureRandom.uuid,
      category: frozen_cat,
      metadata: { "working_directory" => "/tmp/frozen" }
    )

    post refresh_category_sessions_url, params: { category_id: frozen_cat.id }

    assert_redirected_to root_path
    assert_match /Frozen categories are excluded/, flash[:alert]
    assert_equal "failed", frozen_failed.reload.status
  end

  # An unknown category id is rejected rather than silently refreshing nothing.
  test "refresh_category with unknown category id redirects with an alert" do
    post refresh_category_sessions_url, params: { category_id: 999_999 }

    assert_redirected_to root_path
    assert_match /Category not found/, flash[:alert]
  end

  # Frozen-category sessions are a parked bucket excluded from bulk refresh.
  test "refresh_all leaves a failed session in a frozen category untouched" do
    frozen_cat = Category.create!(name: "parked backlog", is_frozen: true)
    frozen_failed = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "parked",
      status: :failed,
      category: frozen_cat
    )

    post refresh_all_sessions_url
    assert_redirected_to root_path

    # Excluded from the query entirely, so it is never restarted and stays failed.
    assert_equal "failed", frozen_failed.reload.status
    refute frozen_failed.logs.where("content LIKE ?", "Restarting failed session%").exists?
  end

  # Test refresh_all also restarts failed sessions
  test "refresh_all should restart failed sessions" do
    # First archive all existing non-failed sessions so we only test our new ones
    Session.where.not(status: [ :failed, :archived ]).each { |s| s.update!(status: :archived) }
    Session.where(status: :failed).each { |s| s.update!(status: :archived) }

    # Create some failed sessions with required metadata
    failed1 = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Failed test 1",
      status: :failed,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/test1" }
    )
    failed2 = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Failed test 2",
      status: :failed,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/test2" }
    )

    # Stub directory existence check - allow any Dir.exist? call
    Dir.stubs(:exist?).returns(true)

    post refresh_all_sessions_url

    # Both sessions should be transitioned to running
    failed1.reload
    failed2.reload
    assert_equal "running", failed1.status
    assert_equal "running", failed2.status
    assert_redirected_to root_path
    assert_match /Restarted 2 failed session/, flash[:notice]
  end

  test "refresh_all should handle sessions that cannot be restarted" do
    # First archive all existing sessions so we only test our new one
    Session.where.not(status: :archived).each { |s| s.update!(status: :archived) }

    # A session that HAS a conversation but no session_id to resume it under:
    # the one shape restart genuinely cannot handle. A session with no
    # transcript either has simply never run, and is restarted from scratch
    # rather than counted as an error (zimmer#557).
    failed1 = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Failed test",
      status: :failed,
      transcript: %({"type":"user","message":{"role":"user","content":"Hi"}}\n),
      # Missing session_id and working_directory
      metadata: {}
    )

    post refresh_all_sessions_url

    # Session should remain failed
    failed1.reload
    assert_equal "failed", failed1.status
    assert_redirected_to root_path
    # Should show error in flash (either alert or notice with error count)
    assert flash[:alert]&.include?("Failed to process") || flash[:notice]&.include?("error"),
           "Expected error message in flash, got: alert=#{flash[:alert]}, notice=#{flash[:notice]}"
  end

  test "refresh_all should reset sigterm retry metadata when restarting failed sessions" do
    # First archive all existing sessions so we only test our new one
    Session.where.not(status: :archived).each { |s| s.update!(status: :archived) }

    failed1 = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Failed test",
      status: :failed,
      session_id: SecureRandom.uuid,
      metadata: {
        "working_directory" => "/tmp/test",
        "sigterm_retry_count" => 3,
        "sigterm_retry_timestamps" => [ "2025-11-29T18:21:47Z" ],
        "last_sigterm_at" => "2025-11-29T18:21:47Z"
      }
    )

    # Stub all Dir.exist? calls
    Dir.stubs(:exist?).returns(true)

    post refresh_all_sessions_url

    failed1.reload
    # SIGTERM retry metadata should be cleared
    assert_nil failed1.metadata["sigterm_retry_count"]
    assert_nil failed1.metadata["sigterm_retry_timestamps"]
    assert_nil failed1.metadata["last_sigterm_at"]
    # Other metadata should be preserved
    assert_equal "/tmp/test", failed1.metadata["working_directory"]
  end

  test "refresh_all should both refresh and restart in single call" do
    # Create a running session (will be refreshed)
    running_session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Running test", status: :running)
    clone_path = "/fake/clone/path/#{running_session.id}"
    running_session.update!(metadata: { "clone_path" => clone_path })

    # Create a failed session (will be restarted)
    Session.where(status: :failed).each { |s| s.update!(status: :archived) }
    failed_session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Failed test",
      status: :failed,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/test_combined" }
    )

    # Stub for transcript refresh
    transcript_content = "{\"role\":\"user\",\"content\":\"Test message\"}\n"
    fake_transcript_file = "/fake/.claude/projects/-fake-clone-path-#{running_session.id}/test-session.jsonl"
    Dir.expects(:exist?).with(anything).returns(true).at_least_once
    Dir.expects(:glob).returns([ fake_transcript_file ]).at_least_once
    File.expects(:mtime).returns(Time.current).at_least_once
    File.expects(:read).returns(transcript_content).at_least_once

    post refresh_all_sessions_url

    # Running session should have transcript refreshed
    running_session.reload
    assert_not_nil running_session.transcript

    # Failed session should be restarted (transitioned to running)
    failed_session.reload
    assert_equal "running", failed_session.status

    assert_redirected_to root_path
    # Notice should mention both refreshed and restarted sessions
    assert_match /Refreshed.*session/, flash[:notice]
    assert_match /Restarted.*failed session/, flash[:notice]
  end

  test "bulk restart limit constant is defined" do
    assert_equal 50, SessionsController::BULK_RESTART_LIMIT
  end

  test "refresh_all should respect BULK_RESTART_LIMIT and warn about remaining sessions" do
    # Archive all existing sessions
    Session.where.not(status: :archived).each { |s| s.update!(status: :archived) }

    # Create 55 failed sessions (5 more than the limit of 50)
    55.times do |i|
      Session.create!(
        git_root: "https://github.com/test/repo.git",
        prompt: "Failed test #{i}",
        status: :failed,
        session_id: SecureRandom.uuid,
        metadata: { "working_directory" => "/tmp/test#{i}" }
      )
    end

    Dir.stubs(:exist?).returns(true)

    post refresh_all_sessions_url

    # Only 50 sessions should be restarted
    restarted_count = Session.where(status: :running).count
    assert_equal 50, restarted_count

    # 5 sessions should remain failed
    failed_count = Session.where(status: :failed).count
    assert_equal 5, failed_count

    # Flash should warn about remaining sessions
    assert_match /5 more .* to restart\/continue/, flash[:notice]
  end

  test "refresh_all should continue needs_input sessions" do
    # Archive all existing sessions so we only test our new ones
    Session.where.not(status: :archived).each { |s| s.update!(status: :archived) }

    # Create needs_input sessions with required metadata (simulating post-deploy state)
    needs_input1 = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Paused test 1",
      status: :needs_input,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/test1" }
    )
    needs_input2 = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Paused test 2",
      status: :needs_input,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/test2" }
    )

    # Stub directory existence check
    Dir.stubs(:exist?).returns(true)

    post refresh_all_sessions_url

    # Both sessions should be transitioned to running
    needs_input1.reload
    needs_input2.reload
    assert_equal "running", needs_input1.status
    assert_equal "running", needs_input2.status
    assert_redirected_to root_path
    assert_match /Continued 2 paused session/, flash[:notice]
  end

  test "refresh_all should continue both failed and needs_input sessions" do
    # Archive all existing sessions
    Session.where.not(status: :archived).each { |s| s.update!(status: :archived) }

    # Create one failed and one needs_input session
    failed_session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Failed test",
      status: :failed,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/failed" }
    )
    needs_input_session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Paused test",
      status: :needs_input,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/paused" }
    )

    Dir.stubs(:exist?).returns(true)

    post refresh_all_sessions_url

    failed_session.reload
    needs_input_session.reload
    assert_equal "running", failed_session.status
    assert_equal "running", needs_input_session.status
    assert_redirected_to root_path
    assert_match /Restarted 1 failed session/, flash[:notice]
    assert_match /Continued 1 paused session/, flash[:notice]
  end

  test "refresh_all bulk limit applies across failed and needs_input sessions" do
    # Archive all existing sessions
    Session.where.not(status: :archived).each { |s| s.update!(status: :archived) }

    # Create 30 failed sessions
    30.times do |i|
      Session.create!(
        git_root: "https://github.com/test/repo.git",
        prompt: "Failed test #{i}",
        status: :failed,
        session_id: SecureRandom.uuid,
        metadata: { "working_directory" => "/tmp/failed#{i}" }
      )
    end

    # Create 30 needs_input sessions
    30.times do |i|
      Session.create!(
        git_root: "https://github.com/test/repo.git",
        prompt: "Paused test #{i}",
        status: :needs_input,
        session_id: SecureRandom.uuid,
        metadata: { "working_directory" => "/tmp/paused#{i}" }
      )
    end

    Dir.stubs(:exist?).returns(true)

    post refresh_all_sessions_url

    # All 30 failed sessions should be restarted (prioritized)
    restarted_count = Session.where(status: :running).count
    assert_equal 50, restarted_count

    # 20 needs_input sessions should have been continued (50 - 30 = 20 remaining limit)
    remaining_needs_input = Session.where(status: :needs_input).count
    assert_equal 10, remaining_needs_input

    # Flash should warn about remaining sessions (10 needs_input still pending)
    assert_match /10 more .* to restart\/continue/, flash[:notice]
  end

  test "refresh_all should NOT continue user-paused sessions" do
    # Archive all existing sessions
    Session.where.not(status: :archived).each { |s| s.update!(status: :archived) }

    # Create a session paused by the user (should NOT be continued)
    user_paused = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "User paused test",
      status: :needs_input,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/user_paused", "paused_by" => "user" }
    )

    # Create a session paused by recovery (SHOULD be continued)
    recovery_paused = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Recovery paused test",
      status: :needs_input,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/recovery_paused", "paused_by" => "recovery" }
    )

    # Create a session without paused_by (backwards compatibility - SHOULD be continued)
    legacy_paused = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Legacy paused test",
      status: :needs_input,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/legacy_paused" }
    )

    Dir.stubs(:exist?).returns(true)

    post refresh_all_sessions_url

    user_paused.reload
    recovery_paused.reload
    legacy_paused.reload

    # User-paused session should remain in needs_input
    assert_equal "needs_input", user_paused.status

    # Recovery-paused and legacy (no paused_by) sessions should be continued
    assert_equal "running", recovery_paused.status
    assert_equal "running", legacy_paused.status

    assert_redirected_to root_path
    assert_match /Continued 2 paused session/, flash[:notice]
  end

  test "refresh_all should clear paused_by metadata when continuing sessions" do
    # Archive all existing sessions
    Session.where.not(status: :archived).each { |s| s.update!(status: :archived) }

    # Create a session paused by recovery
    recovery_paused = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Recovery paused test",
      status: :needs_input,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/test", "paused_by" => "recovery" }
    )

    Dir.stubs(:exist?).returns(true)

    post refresh_all_sessions_url

    recovery_paused.reload
    assert_equal "running", recovery_paused.status
    # paused_by should be cleared after restart
    assert_nil recovery_paused.metadata["paused_by"]
    # working_directory should be preserved
    assert_equal "/tmp/test", recovery_paused.metadata["working_directory"]
  end

  # Test update_mcp_servers action
  test "should update session mcp_servers" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [ "playwright-custom" ])

    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: [ "playwright-custom", "twist-wolfbot" ] },
          as: :json

    assert_response :success
    session.reload
    assert_equal [ "playwright-custom", "twist-wolfbot" ], session.mcp_servers

    json_response = JSON.parse(response.body)
    assert_equal true, json_response["success"]
    assert_equal [ "playwright-custom", "twist-wolfbot" ], json_response["mcp_servers"]
  end

  # The form emits a blank hidden input when nothing is selected, so an empty
  # list is a user who deliberately picked no servers. Without recording that,
  # McpServerBackfill reads the empty column as an accident and restores the
  # root's defaults the next time the config is regenerated.
  test "clearing mcp_servers from the UI records the choice as deliberate" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [ "playwright-custom" ])

    patch update_mcp_servers_session_url(session), params: { mcp_servers: [] }, as: :json

    assert_response :success
    session.reload
    assert_equal [], session.mcp_servers
    assert session.mcp_servers_explicitly_empty?
  end

  test "selecting mcp_servers again clears the deliberate-none flag" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [])
    patch update_mcp_servers_session_url(session), params: { mcp_servers: [] }, as: :json
    assert session.reload.mcp_servers_explicitly_empty?

    patch update_mcp_servers_session_url(session), params: { mcp_servers: [ "context7" ] }, as: :json

    assert_response :success
    refute session.reload.mcp_servers_explicitly_empty?
  end

  test "should create log when updating mcp_servers" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [ "playwright-custom" ])

    assert_difference "session.logs.count", 1 do
      patch update_mcp_servers_session_url(session),
            params: { mcp_servers: [ "playwright-custom", "twist-wolfbot" ] },
            as: :json
    end

    session.reload
    log = session.logs.last
    assert_equal "info", log.level
    assert_includes log.content, "MCP servers updated"
    assert_includes log.content, "added: twist-wolfbot"
  end

  test "should log added and removed mcp_servers" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [ "playwright-custom", "twist-wolfbot" ])

    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: [ "context7" ] },
          as: :json

    assert_response :success
    session.reload
    log = session.logs.last
    assert_includes log.content, "added: context7"
    assert_includes log.content, "removed: playwright-custom, twist-wolfbot"
  end

  test "should not create log when mcp_servers unchanged" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [ "playwright-custom" ])

    assert_no_difference "session.logs.count" do
      patch update_mcp_servers_session_url(session),
            params: { mcp_servers: [ "playwright-custom" ] },
            as: :json
    end

    assert_response :success
  end

  test "should clear mcp_servers with empty array" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [ "playwright-custom" ])

    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: [] },
          as: :json

    assert_response :success
    session.reload
    assert_equal [], session.mcp_servers
  end

  test "clearing oauth-required mcp_servers removes stale oauth metadata" do
    ServersConfig.stubs(:exists?).with("linear").returns(true)
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      status: :failed,
      mcp_servers: [ "linear" ],
      metadata: {
        "failure_reason" => "oauth_required",
        "oauth_required_servers" => [
          { "server_name" => "linear", "server_url" => "https://mcp.linear.app/mcp" }
        ]
      }
    )

    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: [] },
          as: :json

    assert_response :success
    session.reload
    assert_equal [], session.mcp_servers
    assert_nil session.metadata["failure_reason"]
    assert_nil session.metadata["oauth_required_servers"]
  end

  test "should reject invalid mcp_servers" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [ "playwright-custom" ])

    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: [ "invalid-server-name" ] },
          as: :json

    assert_response :unprocessable_entity
    session.reload
    # Should remain unchanged
    assert_equal [ "playwright-custom" ], session.mcp_servers

    json_response = JSON.parse(response.body)
    assert_includes json_response["error"], "Invalid MCP servers"
    assert_includes json_response["error"], "invalid-server-name"
  end

  test "should strip blank mcp_servers values" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [])

    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: [ "playwright-custom", "", "  " ] },
          as: :json

    assert_response :success
    session.reload
    # Should only have the non-blank server
    assert_equal [ "playwright-custom" ], session.mcp_servers
  end

  test "should handle nil mcp_servers param" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [ "playwright-custom" ])

    patch update_mcp_servers_session_url(session),
          params: {},  # No mcp_servers param at all
          as: :json

    assert_response :success
    session.reload
    # Should result in empty array
    assert_equal [], session.mcp_servers
  end

  test "should route to update_mcp_servers" do
    assert_routing(
      { method: :patch, path: "/sessions/1/update_mcp_servers" },
      { controller: "sessions", action: "update_mcp_servers", id: "1" }
    )
  end

  test "update_mcp_servers responds with turbo_stream replacing display partials" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [ "playwright-custom" ])

    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: [ "playwright-custom", "twist-wolfbot" ] },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.media_type + "; charset=" + response.charset
    # Should contain turbo-stream replace actions for both display regions
    assert_match /<turbo-stream action="replace" target="session_#{session.id}_metadata">/, response.body
    assert_match /<turbo-stream action="replace" target="session_#{session.id}_mobile_mcp_servers">/, response.body
    # Persisted change must be reflected
    session.reload
    assert_equal [ "playwright-custom", "twist-wolfbot" ], session.mcp_servers
  end

  test "show page should include servers_for_select data" do
    session = sessions(:running)

    get session_url(session)
    assert_response :success

    # Check that the available servers are included in the page
    # They should be in a data attribute for the editable MCP servers controller
    assert_match /data-editable-mcp-servers-available-servers-value/, response.body
  end

  test "show page renders oauth required prompt in mobile visible header" do
    session = sessions(:pending_oauth)

    get session_url(session)
    assert_response :success

    assert_match /class="md:hidden mt-3"/, response.body
    assert_includes response.body, "OAuth Authorization Required"
    assert_includes response.body, "Authorize linear"
  end

  # #195: a grant renewed while the session was already live cannot reach the
  # running agent, so the page has to say so — otherwise the user sees
  # "Successfully authorized" and a session with no tools from that server.
  test "show page renders the MCP OAuth reconnect notice for a live session" do
    session = sessions(:running)
    session.merge_metadata!(
      Session::MCP_OAUTH_RECONNECT_KEY => {
        "servers" => [ "notion" ], "authorized_at" => Time.current.iso8601
      }
    )

    get session_url(session)
    assert_response :success

    assert_includes response.body, "Authorization complete — reconnects on the next turn"
    assert_includes response.body, "Queue a reconnect message"
    # The button is an ordinary follow-up, not a bespoke resume path: on a running
    # session follow_up queues the message rather than interrupting the turn.
    assert_includes response.body, "action=\"#{follow_up_session_path(session)}\""
  end

  test "show page drops the reconnect notice once the session is no longer live" do
    session = sessions(:running)
    session.merge_metadata!(
      Session::MCP_OAUTH_RECONNECT_KEY => {
        "servers" => [ "notion" ], "authorized_at" => Time.current.iso8601
      }
    )
    session.update_column(:status, "archived")

    get session_url(session)
    assert_response :success

    assert_not_includes response.body, "Authorization complete — reconnects on the next turn"
  end

  test "should reject non-array mcp_servers param" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [])

    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: "not-an-array" },
          as: :json

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_includes json_response["error"], "must be an array"
  end

  test "should limit mcp_servers array size" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [])
    large_array = Array.new(51, "playwright-custom")

    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: large_array },
          as: :json

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_includes json_response["error"], "Too many MCP servers"
  end

  test "should truncate long server names" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", mcp_servers: [])
    # 101 characters, should be truncated to 100
    long_name = "a" * 101

    # This will fail validation because the truncated name won't exist in the catalog
    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: [ long_name ] },
          as: :json

    assert_response :unprocessable_entity
    # The error should mention the truncated name (100 chars)
    json_response = JSON.parse(response.body)
    assert_includes json_response["error"], "Invalid MCP servers"
  end

  # The regeneration policy, asserted rather than assumed: a catalog-selection
  # change persists and stops. AIR is not run, so the clone's .mcp.json is left
  # exactly as it was until the session's next prepare — its next turn, a
  # restart, or an unarchive, each of which re-runs AIR anyway.
  test "updating mcp_servers does not regenerate the clone's mcp.json" do
    Dir.mktmpdir do |temp_dir|
      mcp_path = File.join(temp_dir, ".mcp.json")
      original_content = '{"mcpServers": {"old-server": {"command": "test"}}}'
      File.write(mcp_path, original_content)

      session = Session.create!(
        git_root: "https://github.com/test/repo.git",
        prompt: "Test prompt",
        mcp_servers: [],
        metadata: { "working_directory" => temp_dir }
      )

      AirPrepareService.any_instance.expects(:prepare!).never

      patch update_mcp_servers_session_url(session),
            params: { mcp_servers: [ "playwright-custom" ] },
            as: :json

      assert_response :success
      assert_equal [ "playwright-custom" ], session.reload.mcp_servers
      assert_equal original_content, File.read(mcp_path),
        "the write must not touch the clone's runtime config"
    end
  end

  test "should handle mcp_servers update when working directory does not exist" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      mcp_servers: [ "playwright-custom" ],
      metadata: { "working_directory" => "/nonexistent/path" }
    )

    # Should not raise an error, just skip regeneration (no file to write)
    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: [ "context7" ] },
          as: :json

    assert_response :success
    session.reload
    assert_equal [ "context7" ], session.mcp_servers
  end

  test "should handle mcp_servers update when no working directory in metadata" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      mcp_servers: [ "playwright-custom" ],
      metadata: {}
    )

    # Should not raise an error, just skip regeneration (no working dir)
    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: [ "context7" ] },
          as: :json

    assert_response :success
    session.reload
    assert_equal [ "context7" ], session.mcp_servers
  end

  test "should handle mcp_servers update when metadata is nil" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      mcp_servers: [ "playwright-custom" ]
    )
    # Ensure metadata is nil
    session.update_column(:metadata, nil)

    # Should not raise an error, just skip regeneration (no metadata)
    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: [ "context7" ] },
          as: :json

    assert_response :success
    session.reload
    assert_equal [ "context7" ], session.mcp_servers
  end

  test "updating catalog_plugins does not regenerate the clone's mcp.json" do
    Dir.mktmpdir do |temp_dir|
      session = Session.create!(
        git_root: "https://github.com/test/repo.git",
        prompt: "Test prompt",
        mcp_servers: [ "remote-fs-screenshots" ],
        catalog_plugins: [],
        metadata: { "working_directory" => temp_dir }
      )

      AirPrepareService.any_instance.expects(:prepare!).never
      McpOauthCredentialInjector.any_instance.stubs(:check_credentials_status).returns({})

      patch update_catalog_plugins_session_url(session),
            params: { catalog_plugins: [ "figma-design-workflow" ] },
            as: :json

      assert_response :success
      session.reload
      assert_equal [ "figma-design-workflow" ], session.catalog_plugins
      # The servers the plugin bundles are part of the session's effective set
      # immediately; only the on-disk config waits for the next prepare.
      assert_includes session.all_mcp_servers, "remote-fs-screenshots"
      assert_includes session.all_mcp_servers, "figma"
      assert_includes session.all_mcp_servers, "image-diff"
      assert_includes session.all_mcp_servers, "svg-tracer"
      assert_includes session.all_mcp_servers, "playwright-custom"
    end
  end

  test "clearing mcp_servers leaves the clone's mcp.json for the next prepare" do
    Dir.mktmpdir do |temp_dir|
      session = Session.create!(
        git_root: "https://github.com/test/repo.git",
        prompt: "Test prompt",
        mcp_servers: [ "playwright-custom" ],
        metadata: { "working_directory" => temp_dir }
      )

      mcp_path = File.join(temp_dir, ".mcp.json")
      File.write(mcp_path, '{"mcpServers": {"playwright-custom": {}}}')

      AirPrepareService.any_instance.expects(:prepare!).never

      patch update_mcp_servers_session_url(session),
            params: { mcp_servers: [] },
            as: :json

      assert_response :success
      assert_equal [], session.reload.mcp_servers
      assert_equal({ "playwright-custom" => {} }, JSON.parse(File.read(mcp_path))["mcpServers"],
        "the on-disk config is rewritten by the next prepare, not by the write")
    end
  end

  # --- The four catalog editors, one rule --------------------------------------
  #
  # The web third of the 4 x 3 matrix. All four editors run through
  # Sessions::UpdateCatalogSelection, so the cap, the truncation, the unknown-id
  # rejection, the log row and the regeneration policy are one behaviour with
  # four names — asserted here against the same table the REST and MCP surfaces
  # are asserted against.
  WEB_CATALOG_EDITORS = [
    { attribute: :mcp_servers, path: :update_mcp_servers_session_url },
    { attribute: :catalog_skills, path: :update_catalog_skills_session_url },
    { attribute: :catalog_hooks, path: :update_catalog_hooks_session_url },
    { attribute: :catalog_plugins, path: :update_catalog_plugins_session_url }
  ].freeze

  def catalog_session(label)
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Matrix #{label}")
  end

  def patch_catalog(editor, session, values)
    patch send(editor[:path], session), params: { editor[:attribute] => values }, as: :json
  end

  test "every catalog editor enforces its cap" do
    WEB_CATALOG_EDITORS.each do |editor|
      spec = Session::CATALOG_SELECTIONS.fetch(editor[:attribute])
      valid = Sessions::UpdateCatalogSelection.valid_ids(editor[:attribute]).first

      patch_catalog(editor, catalog_session(editor[:attribute]), Array.new(spec[:max] + 1, valid))

      assert_response :unprocessable_entity, editor[:attribute].to_s
      assert_equal "Too many #{spec[:label]} (maximum #{spec[:max]})",
        JSON.parse(response.body)["error"], editor[:attribute].to_s
    end
  end

  test "every catalog editor truncates an over-long id before validating it" do
    over_long = "z" * (Session::MAX_CATALOG_SELECTION_ID_LENGTH + 25)

    WEB_CATALOG_EDITORS.each do |editor|
      patch_catalog(editor, catalog_session(editor[:attribute]), [ over_long ])

      assert_response :unprocessable_entity, editor[:attribute].to_s
      error = JSON.parse(response.body)["error"]
      assert_includes error, "z" * Session::MAX_CATALOG_SELECTION_ID_LENGTH
      assert_not_includes error, over_long, "#{editor[:attribute]} echoed the untruncated id"
    end
  end

  test "every catalog editor rejects an id outside its catalog and leaves the list alone" do
    WEB_CATALOG_EDITORS.each do |editor|
      spec = Session::CATALOG_SELECTIONS.fetch(editor[:attribute])
      session = catalog_session(editor[:attribute])

      patch_catalog(editor, session, [ "no-such-entry" ])

      assert_response :unprocessable_entity, editor[:attribute].to_s
      assert_equal "Invalid #{spec[:label]}: no-such-entry", JSON.parse(response.body)["error"]
      assert_equal [], session.reload.public_send(editor[:attribute]).to_a
    end
  end

  test "every catalog editor writes one log row with no surface suffix" do
    WEB_CATALOG_EDITORS.each do |editor|
      spec = Session::CATALOG_SELECTIONS.fetch(editor[:attribute])
      session = catalog_session(editor[:attribute])
      id = Sessions::UpdateCatalogSelection.valid_ids(editor[:attribute]).first

      assert_difference -> { session.logs.count }, 1, editor[:attribute].to_s do
        patch_catalog(editor, session, [ id ])
      end

      assert_response :success
      assert_equal "#{spec[:label].upcase_first} updated (added: #{id})", session.logs.last.content
    end
  end

  test "no catalog editor regenerates the session's runtime config" do
    Dir.mktmpdir do |dir|
      AirPrepareService.any_instance.expects(:prepare!).never
      McpOauthCredentialInjector.any_instance.stubs(:check_credentials_status).returns({})

      WEB_CATALOG_EDITORS.each do |editor|
        session = Session.create!(
          git_root: "https://github.com/test/repo.git",
          prompt: "Matrix #{editor[:attribute]}",
          metadata: { "working_directory" => dir }
        )
        id = Sessions::UpdateCatalogSelection.valid_ids(editor[:attribute]).first

        patch_catalog(editor, session, [ id ])

        assert_response :success, editor[:attribute].to_s
        assert_equal [ id ], session.reload.public_send(editor[:attribute])
      end
    end
  end

  # Test toggle_favorite action
  test "should toggle favorite from false to true" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", favorited: false)

    # With referrer from sessions index, should redirect back there
    patch toggle_favorite_session_url(session), headers: { "HTTP_REFERER" => root_url }

    assert_redirected_to root_path
    session.reload
    assert_equal true, session.favorited
  end

  test "should toggle favorite from true to false" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", favorited: true)

    # With referrer from sessions index, should redirect back there
    patch toggle_favorite_session_url(session), headers: { "HTTP_REFERER" => root_url }

    assert_redirected_to root_path
    session.reload
    assert_equal false, session.favorited
  end

  test "should return json response for toggle_favorite" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", favorited: false)

    patch toggle_favorite_session_url(session), as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal true, json_response["success"]
    assert_equal true, json_response["favorited"]
  end

  test "should route to toggle_favorite" do
    assert_routing(
      { method: :patch, path: "/sessions/1/toggle_favorite" },
      { controller: "sessions", action: "toggle_favorite", id: "1" }
    )
  end

  # Test favorites sorted first in index
  test "should list favorited sessions before non-favorited sessions" do
    # Clean up to ensure we have control over session order
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    # Create sessions in specific order
    old_favorited = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Old Favorited", created_at: 2.days.ago, favorited: true)
    new_unfavorited = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "New Unfavorited", created_at: 1.hour.ago, favorited: false)
    old_unfavorited = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Old Unfavorited", created_at: 1.day.ago, favorited: false)
    new_favorited = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "New Favorited", created_at: 1.minute.ago, favorited: true)

    get root_url(every_status_params)
    assert_response :success

    # Get the order of sessions in the response
    # The session IDs should appear in order: favorited first (by created_at desc), then unfavorited (by created_at desc)
    response_body = response.body

    # Find positions of each session ID in the response
    new_favorited_pos = response_body.index(new_favorited.id.to_s)
    old_favorited_pos = response_body.index(old_favorited.id.to_s)
    new_unfavorited_pos = response_body.index(new_unfavorited.id.to_s)
    old_unfavorited_pos = response_body.index(old_unfavorited.id.to_s)

    # Favorited sessions should appear before unfavorited ones
    assert new_favorited_pos < new_unfavorited_pos, "New favorited should appear before new unfavorited"
    assert new_favorited_pos < old_unfavorited_pos, "New favorited should appear before old unfavorited"
    assert old_favorited_pos < new_unfavorited_pos, "Old favorited should appear before new unfavorited"
    assert old_favorited_pos < old_unfavorited_pos, "Old favorited should appear before old unfavorited"

    # Within favorited, newer should come first
    assert new_favorited_pos < old_favorited_pos, "New favorited should appear before old favorited"

    # Within unfavorited, newer should come first
    assert new_unfavorited_pos < old_unfavorited_pos, "New unfavorited should appear before old unfavorited"
  end

  test "favorite star should appear in session card" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", favorited: false)

    get root_url(every_status_params)
    assert_response :success

    # Should have the toggle_favorite form/button
    assert_select "form[action=?]", toggle_favorite_session_path(session)
  end

  test "should render turbo_stream response for toggle_favorite" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", favorited: false)

    patch toggle_favorite_session_url(session), as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    assert_match(/turbo-stream/, response.body)
    assert_match(/action="replace"/, response.body)
    # Should update both session card (for index) and header actions (for detail page)
    assert_match(/session_#{session.id}/, response.body)
    assert_match(/session_#{session.id}_header_actions/, response.body)
  end

  test "should return 404 for toggle_favorite with invalid session" do
    patch toggle_favorite_session_url(id: 99999)
    assert_response :not_found
  end

  test "favorite star should appear in session show page header actions" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", favorited: false)

    get session_url(session)
    assert_response :success

    # Should have the toggle_favorite link in the header actions
    assert_select "a[href=?]", toggle_favorite_session_path(session)
    # Should have the star SVG icon
    assert_select "a[href=?] svg", toggle_favorite_session_path(session)
  end

  # === toggle_push_notifications action ===

  test "should toggle push_notifications_enabled from false to true" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    assert_equal false, session.push_notifications_enabled

    patch toggle_push_notifications_session_url(session)

    assert_redirected_to session_path(session)
    session.reload
    assert_equal true, session.push_notifications_enabled
  end

  test "should toggle push_notifications_enabled from true to false" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", push_notifications_enabled: true)

    patch toggle_push_notifications_session_url(session)

    assert_redirected_to session_path(session)
    session.reload
    assert_equal false, session.push_notifications_enabled
  end

  test "should return json response for toggle_push_notifications" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")

    patch toggle_push_notifications_session_url(session), as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal true, json_response["success"]
    assert_equal true, json_response["push_notifications_enabled"]
  end

  test "should render turbo_stream response for toggle_push_notifications" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")

    patch toggle_push_notifications_session_url(session), as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
    assert_match(/turbo-stream/, response.body)
    assert_match(/action="replace"/, response.body)
    assert_match(/session_#{session.id}_header_actions/, response.body)
  end

  test "should route to toggle_push_notifications" do
    assert_routing(
      { method: :patch, path: "/sessions/1/toggle_push_notifications" },
      { controller: "sessions", action: "toggle_push_notifications", id: "1" }
    )
  end

  test "should return 404 for toggle_push_notifications with invalid session" do
    patch toggle_push_notifications_session_url(id: 99999)
    assert_response :not_found
  end

  test "push notifications bell toggle should appear in session show page header actions" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")

    get session_url(session)
    assert_response :success

    # Toggle link should be present with the right href
    assert_select "a[href=?]", toggle_push_notifications_session_path(session)
    # Outline bell SVG when off
    assert_select "a[href=?] svg", toggle_push_notifications_session_path(session)
    # aria-pressed should reflect off state
    assert_select "a[href=?][aria-pressed=?]", toggle_push_notifications_session_path(session), "false"
  end

  # === heartbeat toggle + interval ===

  test "toggle_heartbeat flips heartbeat_enabled and returns json" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    assert_equal false, session.heartbeat_enabled

    patch toggle_heartbeat_session_url(session), as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_equal true, json["heartbeat_enabled"]
    assert_equal 60, json["heartbeat_interval_seconds"]
    assert_equal true, session.reload.heartbeat_enabled
  end

  test "toggle_heartbeat honors an explicit enabled param" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", heartbeat_enabled: true)

    patch toggle_heartbeat_session_url(session), params: { enabled: false }, as: :json

    assert_response :success
    assert_equal false, session.reload.heartbeat_enabled
  end

  test "update_heartbeat_interval sets a valid interval" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")

    patch update_heartbeat_interval_session_url(session), params: { heartbeat_interval_seconds: 300 }, as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal 300, json["heartbeat_interval_seconds"]
    assert_equal 300, session.reload.heartbeat_interval_seconds
  end

  test "update_heartbeat_interval rejects an out-of-range interval" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")

    patch update_heartbeat_interval_session_url(session), params: { heartbeat_interval_seconds: 1 }, as: :json

    assert_response :unprocessable_entity
    assert_equal 60, session.reload.heartbeat_interval_seconds
  end

  test "should return 404 for toggle_heartbeat with invalid session" do
    patch toggle_heartbeat_session_url(id: 99999), as: :json
    assert_response :not_found
  end

  test "heart toggle should appear in session show page header actions" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")

    get session_url(session)
    assert_response :success

    # The heartbeat Stimulus control renders with the session id value.
    assert_select "[data-controller='heartbeat'][data-heartbeat-session-id-value=?]", session.id.to_s
  end

  test "toggle_favorite should redirect to session show when referrer is session show page" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", favorited: false)

    # Set the referrer to the session show page
    patch toggle_favorite_session_url(session), headers: { "HTTP_REFERER" => session_url(session) }

    assert_redirected_to session_path(session)
    session.reload
    assert_equal true, session.favorited
  end

  test "toggle_favorite should redirect to sessions index when referrer is sessions index" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", favorited: false)

    # Set the referrer to the sessions index page
    patch toggle_favorite_session_url(session), headers: { "HTTP_REFERER" => root_url }

    assert_redirected_to root_path
    session.reload
    assert_equal true, session.favorited
  end

  test "toggle_favorite should redirect to sessions index when no referrer" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", favorited: false)

    # No referrer header
    patch toggle_favorite_session_url(session)

    # Default behavior without referrer should redirect to session show page
    # (since we changed the logic to check for sessions_path in referrer)
    assert_redirected_to session_path(session)
    session.reload
    assert_equal true, session.favorited
  end

  test "new sessions default to is_autonomous true" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")

    assert_equal true, session.is_autonomous
  end

  # Test OAuth detection in update_mcp_servers
  test "update_mcp_servers should return oauth_required for OAuth-protected servers" do
    # Create a session with a working directory so OAuth check can run
    Dir.mktmpdir do |temp_dir|
      session = Session.create!(
        git_root: "https://github.com/test/repo.git",
        prompt: "Test prompt",
        mcp_servers: [],
        metadata: { "working_directory" => temp_dir }
      )

      # Add an OAuth-protected server (notion uses streamable-http which triggers OAuth check)
      # Note: In production this would probe the server, but the response indicates OAuth detection works
      patch update_mcp_servers_session_url(session),
            params: { mcp_servers: [ "notion" ] },
            as: :json

      assert_response :success
      json_response = JSON.parse(response.body)
      assert_equal true, json_response["success"]
      assert_equal [ "notion" ], json_response["mcp_servers"]
      # The response should include oauth_required fields (may be true or false depending on probe)
      assert json_response.key?("oauth_required"), "Response should include oauth_required field"
      assert json_response.key?("oauth_required_servers"), "Response should include oauth_required_servers field"
    end
  end

  test "update_mcp_servers should not require oauth for stdio servers" do
    Dir.mktmpdir do |temp_dir|
      session = Session.create!(
        git_root: "https://github.com/test/repo.git",
        prompt: "Test prompt",
        mcp_servers: [],
        metadata: { "working_directory" => temp_dir }
      )

      # Add a stdio server (playwright-custom) - these never require OAuth
      patch update_mcp_servers_session_url(session),
            params: { mcp_servers: [ "playwright-custom" ] },
            as: :json

      assert_response :success
      json_response = JSON.parse(response.body)
      assert_equal true, json_response["success"]
      assert_equal false, json_response["oauth_required"]
      assert_equal [], json_response["oauth_required_servers"]
    end
  end

  test "update_mcp_servers should skip oauth check when no working_directory" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test prompt",
      mcp_servers: []
      # No metadata set - working_directory will be nil
    )

    patch update_mcp_servers_session_url(session),
          params: { mcp_servers: [ "notion" ] },
          as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal true, json_response["success"]
    # Should return empty oauth_required_servers since we can't check without working_directory
    assert_equal false, json_response["oauth_required"]
    assert_equal [], json_response["oauth_required_servers"]
  end

  # Quick prompt action
  test "quick_prompt creates session via router agent root and redirects" do
    stub_router_agent_root

    assert_difference("Session.count", 1) do
      post quick_prompt_sessions_url, params: { prompt: "Fix the login bug" }
    end

    session = Session.last
    assert_equal "Fix the login bug", session.prompt
    assert_equal "quick_prompt", session.metadata["source"]
    assert_redirected_to session_path(session)
  end

  # Exercises the real shipped catalog (no AgentRootsConfig.find! stub): a router
  # root missing from roots.json raises AgentRootNotFoundError here, which the
  # stubbed tests above cannot catch.
  test "quick_prompt resolves the router root from the real catalog and dispatches" do
    AgentSessionJob.stubs(:enqueue_new_session)

    assert_difference("Session.count", 1) do
      post quick_prompt_sessions_url, params: { prompt: "Add a healthcheck endpoint" }
    end

    session = Session.last
    assert_equal AgentRootsConfig.router_root_name, session.metadata["agent_root_key"]
    assert_equal AgentRootsConfig.find!(AgentRootsConfig.router_root_name).url, session.git_root
    assert_redirected_to session_path(session)
  end

  test "quick_prompt rejects blank prompt" do
    post quick_prompt_sessions_url, params: { prompt: "   " }
    assert_redirected_to root_path
    assert_equal "Prompt cannot be empty.", flash[:alert]
  end

  test "quick_prompt rejects missing prompt param" do
    post quick_prompt_sessions_url, params: {}
    assert_redirected_to root_path
    assert_equal "Prompt cannot be empty.", flash[:alert]
  end

  test "quick_prompt rejects prompt exceeding max length" do
    long_prompt = "a" * (Session::PROMPT_MAX_LENGTH + 1)
    post quick_prompt_sessions_url, params: { prompt: long_prompt }
    assert_redirected_to root_path
    assert_match(/too long/, flash[:alert])
  end

  test "quick_prompt handles missing router agent root gracefully" do
    AgentRootsConfig.stubs(:find!).raises(
      AgentRootsConfig::AgentRootNotFoundError.new("Agent root 'zimmer-orchestrator' not found")
    )

    post quick_prompt_sessions_url, params: { prompt: "Test prompt" }
    assert_redirected_to root_path
    assert_match(/Router agent root not configured/, flash[:alert])
  end

  test "quick_prompt handles session creation failure gracefully" do
    AgentRootsConfig.stubs(:find!).raises(
      ActiveRecord::RecordInvalid.new(Session.new)
    )

    post quick_prompt_sessions_url, params: { prompt: "Test prompt" }
    assert_redirected_to root_path
    assert_match(/Failed to create session/, flash[:alert])
  end

  # Chat bubble action
  test "chat_bubble creates session and returns JSON" do
    stub_router_agent_root

    assert_difference("Session.count", 1) do
      post chat_bubble_sessions_url,
        params: { prompt: "Fix the login bug", page_context: "# Dashboard\nSome content", current_url: "http://localhost:3000/sessions" },
        as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert json["session_id"].present?
    assert json["session_url"].present?

    session = Session.last
    assert_includes session.prompt, "Fix the login bug"
    assert_includes session.prompt, "<context-about-user's-current-view>"
    assert_includes session.prompt, "# Dashboard"
    assert_equal "chat_bubble", session.metadata["source"]
    assert_equal "Fix the login bug", session.metadata["original_prompt"]
  end

  test "chat_bubble session is named from the human's prompt, not the page-context block" do
    # End to end over the real composition: the controller prepends the block,
    # and the title job — running before any transcript exists, which is the
    # path that produced the corrupted names in #809 — has to name the session
    # after what the human typed.
    stub_router_agent_root

    post chat_bubble_sessions_url,
      params: { prompt: "Fix the login bug", page_context: "# Dashboard\nSome content", current_url: "https://zimmer.example.com/sessions" },
      as: :json
    assert_response :success

    session = Session.last
    assert_includes session.prompt, "<context-about-user's-current-view>"

    # No inference: without a transcript the title is deterministic.
    SessionTitleJob.new.perform(session.id)

    session.reload
    assert_equal "Fix the login bug", session.title
    assert session.slug.start_with?("fix-the-login-bug-"), "unexpected slug #{session.slug.inspect}"
    refute_includes session.slug, "context-about-user"
  end

  test "chat_bubble works without page context" do
    stub_router_agent_root

    post chat_bubble_sessions_url,
      params: { prompt: "Fix the login bug" },
      as: :json

    assert_response :success
    session = Session.last
    assert_equal "Fix the login bug", session.prompt
  end

  test "chat_bubble rejects blank prompt" do
    post chat_bubble_sessions_url,
      params: { prompt: "   " },
      as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Prompt cannot be empty.", json["error"]
  end

  test "chat_bubble rejects prompt exceeding max length" do
    long_prompt = "a" * (Session::PROMPT_MAX_LENGTH + 1)
    post chat_bubble_sessions_url,
      params: { prompt: long_prompt },
      as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/too long/, json["error"])
  end

  test "chat_bubble handles missing router agent root gracefully" do
    AgentRootsConfig.stubs(:find!).raises(
      AgentRootsConfig::AgentRootNotFoundError.new("Agent root 'zimmer-orchestrator' not found")
    )

    post chat_bubble_sessions_url,
      params: { prompt: "Test prompt" },
      as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/Router agent root not configured/, json["error"])
  end

  test "chat_bubble sets parent_session_id column when provided" do
    parent_session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Parent session")

    stub_router_agent_root

    post chat_bubble_sessions_url,
      params: { prompt: "Do something", parent_session_id: parent_session.id },
      as: :json

    assert_response :success
    session = Session.last
    assert_equal parent_session.id, session.parent_session_id
  end

  test "chat_bubble does not set parent_session_id when not provided" do
    stub_router_agent_root

    post chat_bubble_sessions_url,
      params: { prompt: "Do something" },
      as: :json

    assert_response :success
    session = Session.last
    assert_nil session.parent_session_id
  end

  # ---- Quick Router spot opt-in ----
  #
  # The failure mode these guard is a control that renders but is dropped
  # server-side, so every one asserts the persisted column on the created row
  # rather than the response.

  test "quick_prompt stamps spot on the created session when the box is checked" do
    stub_router_agent_root

    assert_difference("Session.count", 1) do
      post quick_prompt_sessions_url, params: { prompt: "Long unattended sweep", scheduling_class: "spot" }
    end

    session = Session.last
    assert_equal SessionGenesis::SPOT, session.scheduling_class
    assert_equal SessionGenesis::SPOT, session.priority_class
    assert_equal SessionGenesis::WEB_UI, session.genesis
  end

  test "quick_prompt leaves scheduling_class NULL when the box is unchecked" do
    stub_router_agent_root

    assert_difference("Session.count", 1) do
      post quick_prompt_sessions_url, params: { prompt: "Fix the login bug" }
    end

    session = Session.last
    assert_nil session.scheduling_class
    assert_equal SessionGenesis::PRIORITY, session.priority_class
  end

  test "quick_prompt ignores a scheduling_class it does not recognize" do
    stub_router_agent_root

    post quick_prompt_sessions_url, params: { prompt: "Fix the login bug", scheduling_class: "urgent" }

    session = Session.last
    assert_nil session.scheduling_class
    assert_equal SessionGenesis::PRIORITY, session.priority_class
  end

  test "quick_prompt does not stamp priority when the box is unchecked" do
    # "priority" is never written by this surface: an unmodified submission must
    # keep deriving from the web_ui genesis so a settings change still moves it.
    stub_router_agent_root

    post quick_prompt_sessions_url, params: { prompt: "Fix the login bug", scheduling_class: "priority" }

    assert_nil Session.last.scheduling_class
  end

  test "quick_prompt ignores a scheduling_class that is not a string" do
    # A hand-rolled request can send scheduling_class[]=spot or a nested hash.
    # `.to_s` on either is not "spot", so both land on nil rather than raising.
    stub_router_agent_root

    post quick_prompt_sessions_url, params: { prompt: "Fix the login bug", scheduling_class: [ "spot" ] }
    assert_nil Session.last.scheduling_class

    post quick_prompt_sessions_url, params: { prompt: "Fix the login bug again", scheduling_class: { value: "spot" } }
    assert_nil Session.last.scheduling_class
  end

  test "quick_prompt spot submission starts the queue when nothing is in it yet" do
    stub_router_agent_root
    # Every row explicitly priority, so the `spot` scope — which also matches rows
    # that merely DERIVE spot from their genesis — has nothing left to match.
    Session.update_all(scheduling_class: SessionGenesis::PRIORITY)

    post quick_prompt_sessions_url, params: { prompt: "First spot session", scheduling_class: "spot" }

    # Nothing to land above, so the queue opens at DEFAULT + SLOT_GAP rather than
    # at DEFAULT — the same gap every other top-of-queue placement leaves.
    assert_equal SessionPrecedence::DEFAULT + SessionPrecedence::SLOT_GAP, Session.last.precedence
  end

  test "quick_prompt lands a spot submission at the top of the spot queue" do
    stub_router_agent_root
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Queued spot work",
      scheduling_class: SessionGenesis::SPOT,
      precedence: 90
    )

    post quick_prompt_sessions_url, params: { prompt: "Long unattended sweep", scheduling_class: "spot" }

    assert_operator Session.last.precedence, :>, 90
  end

  test "quick_prompt leaves precedence at the default for a priority submission" do
    stub_router_agent_root

    post quick_prompt_sessions_url, params: { prompt: "Fix the login bug" }

    assert_equal SessionPrecedence::DEFAULT, Session.last.precedence
  end

  test "chat_bubble stamps spot on the created session when the box is checked" do
    stub_router_agent_root

    post chat_bubble_sessions_url,
      params: { prompt: "Long unattended sweep", scheduling_class: "spot" },
      as: :json

    assert_response :success
    session = Session.last
    assert_equal SessionGenesis::SPOT, session.scheduling_class
    assert_equal SessionGenesis::SPOT, session.priority_class
  end

  test "chat_bubble leaves scheduling_class NULL when the box is unchecked" do
    stub_router_agent_root

    post chat_bubble_sessions_url, params: { prompt: "Do something" }, as: :json

    assert_response :success
    session = Session.last
    assert_nil session.scheduling_class
    assert_equal SessionGenesis::PRIORITY, session.priority_class
  end

  test "chat_bubble spot opt-in wins over a priority parent session" do
    # The bubble declares web_ui genesis so it never INHERITS a class; the
    # submitter's own choice still has to get through.
    parent_session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Parent session")
    stub_router_agent_root

    post chat_bubble_sessions_url,
      params: { prompt: "Do something", parent_session_id: parent_session.id, scheduling_class: "spot" },
      as: :json

    assert_response :success
    session = Session.last
    assert_equal parent_session.id, session.parent_session_id
    assert_equal SessionGenesis::SPOT, session.scheduling_class
  end

  test "chat_bubble spot submission outranks the parent it would otherwise sit above" do
    parent_session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Parent session",
      precedence: 10
    )
    stub_router_agent_root
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Queued spot work",
      scheduling_class: SessionGenesis::SPOT,
      precedence: 90
    )

    post chat_bubble_sessions_url,
      params: { prompt: "Do something", parent_session_id: parent_session.id, scheduling_class: "spot" },
      as: :json

    assert_response :success
    assert_operator Session.last.precedence, :>, 90
  end

  test "chat_bubble leaves the parent precedence bump alone for a priority submission" do
    parent_session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Parent session",
      precedence: 10
    )
    stub_router_agent_root

    post chat_bubble_sessions_url,
      params: { prompt: "Do something", parent_session_id: parent_session.id },
      as: :json

    assert_response :success
    assert_equal 10 + SessionPrecedence::CHILD_BUMP, Session.last.precedence
  end

  # ---- Upload-attachment paths for chat_bubble / quick_prompt ----
  #
  # Cover the new multipart attachment behavior added to these endpoints:
  # - happy path: upload attaches and is forwarded to the new session job
  # - rejection: invalid uploads surface an error rather than silently dropping
  # - count limit: requests over MAX_*_PER_REQUEST are rejected
  # - cleanup: failed runs do not leak temp directories

  PNG_BYTES = [ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1,
                8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73,
                68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, 13,
                10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66,
                96, 130 ].pack("C*").freeze

  test "chat_bubble accepts an image+file attachment and stages them under the new session" do
    stub_router_agent_root

    image = Rack::Test::UploadedFile.new(StringIO.new(PNG_BYTES), "image/png", original_filename: "shot.png")
    file = Rack::Test::UploadedFile.new(StringIO.new("hello world"), "text/plain", original_filename: "notes.txt")

    assert_difference("Session.count", 1) do
      post chat_bubble_sessions_url, params: { prompt: "Look at this", images: [ image ], files: [ file ] }
    end

    assert_response :success
    session = Session.last
    assert_equal "Look at this", session.metadata["original_prompt"]

    images_on_disk = Dir.glob(File.join(ImageStorageService.base_dir, session.id.to_s, "*"))
    files_on_disk = Dir.glob(File.join(FileStorageService.base_dir, session.id.to_s, "*"))
    assert_equal 1, images_on_disk.size, "expected the image to be persisted under the new session dir"
    assert_equal 1, files_on_disk.size, "expected the file to be persisted under the new session dir"

    log = session.logs.find_by("content LIKE ?", "Attached %")
    assert log, "expected an attachment log entry"

    FileUtils.rm_rf(File.join(ImageStorageService.base_dir, session.id.to_s))
    FileUtils.rm_rf(File.join(FileStorageService.base_dir, session.id.to_s))
  end

  test "chat_bubble surfaces an error when an oversize image is rejected" do
    stub_router_agent_root

    oversize = Rack::Test::UploadedFile.new(
      StringIO.new(PNG_BYTES + ("x" * (ImageStorageService::MAX_IMAGE_SIZE + 1))),
      "image/png",
      original_filename: "big.png"
    )

    assert_no_difference("Session.count") do
      post chat_bubble_sessions_url, params: { prompt: "Look at this", images: [ oversize ] }
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/exceeds maximum size|too large|rejected/i, json["error"])
  end

  test "chat_bubble rejects requests exceeding MAX_IMAGES_PER_REQUEST" do
    too_many = (SessionsController::MAX_IMAGES_PER_REQUEST + 1).times.map do |i|
      Rack::Test::UploadedFile.new(StringIO.new(PNG_BYTES), "image/png", original_filename: "img_#{i}.png")
    end

    post chat_bubble_sessions_url, params: { prompt: "x", images: too_many }

    assert_response :unprocessable_entity
    assert_match(/Maximum #{SessionsController::MAX_IMAGES_PER_REQUEST} images/i, JSON.parse(response.body)["error"])
  end

  test "chat_bubble cleans up temp images when an attachment is rejected" do
    AgentRootsConfig.stubs(:find!).never
    AgentSessionJob.stubs(:enqueue_new_session).never

    base_dir = ImageStorageService.base_dir
    before = Dir.glob(File.join(base_dir, "temp_*")).to_set

    bad = Rack::Test::UploadedFile.new(StringIO.new("not an image"), "image/png", original_filename: "fake.png")
    post chat_bubble_sessions_url, params: { prompt: "x", images: [ bad ] }

    assert_response :unprocessable_entity
    after = Dir.glob(File.join(base_dir, "temp_*")).to_set
    leaked = (after - before)
    assert_empty leaked, "expected no temp dirs to leak after rejection (leaked: #{leaked.inspect})"
  end

  test "quick_prompt accepts an image attachment and stages it under the new session" do
    stub_router_agent_root

    image = Rack::Test::UploadedFile.new(StringIO.new(PNG_BYTES), "image/png", original_filename: "shot.png")

    assert_difference("Session.count", 1) do
      post quick_prompt_sessions_url, params: { prompt: "Help", images: [ image ] }
    end

    assert_redirected_to session_path(Session.last)
    images_on_disk = Dir.glob(File.join(ImageStorageService.base_dir, Session.last.id.to_s, "*"))
    assert_equal 1, images_on_disk.size

    FileUtils.rm_rf(File.join(ImageStorageService.base_dir, Session.last.id.to_s))
  end

  test "quick_prompt surfaces a flash alert when an attachment is rejected" do
    bad = Rack::Test::UploadedFile.new(StringIO.new("not an image"), "image/png", original_filename: "fake.png")

    assert_no_difference("Session.count") do
      post quick_prompt_sessions_url, params: { prompt: "Help", images: [ bad ] }
    end

    assert_redirected_to root_path
    assert_match(/upload attachment|rejected|unsupported/i, flash[:alert])
  end

  # Test update_catalog_skills action
  test "should update session catalog_skills" do
    skill_names = SkillsConfig.names.first(2)
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", catalog_skills: [ skill_names.first ])

    patch update_catalog_skills_session_url(session),
          params: { catalog_skills: skill_names },
          as: :json

    assert_response :success
    session.reload
    assert_equal skill_names, session.catalog_skills

    json_response = JSON.parse(response.body)
    assert_equal true, json_response["success"]
    assert_equal skill_names, json_response["catalog_skills"]
  end

  test "should create log when updating catalog_skills" do
    skill_names = SkillsConfig.names.first(2)
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", catalog_skills: [ skill_names.first ])

    assert_difference "session.logs.count", 1 do
      patch update_catalog_skills_session_url(session),
            params: { catalog_skills: skill_names },
            as: :json
    end

    session.reload
    log = session.logs.last
    assert_equal "info", log.level
    assert_includes log.content, "Catalog skills updated"
    assert_includes log.content, "added: #{skill_names.second}"
  end

  test "should log added and removed catalog_skills" do
    skill_names = SkillsConfig.names.first(3)
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", catalog_skills: skill_names[0..1])

    patch update_catalog_skills_session_url(session),
          params: { catalog_skills: [ skill_names.last ] },
          as: :json

    assert_response :success
    session.reload
    log = session.logs.last
    assert_includes log.content, "added: #{skill_names.last}"
    assert_includes log.content, "removed: #{skill_names[0]}, #{skill_names[1]}"
  end

  test "should not create log when catalog_skills unchanged" do
    skill_name = SkillsConfig.names.first
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", catalog_skills: [ skill_name ])

    assert_no_difference "session.logs.count" do
      patch update_catalog_skills_session_url(session),
            params: { catalog_skills: [ skill_name ] },
            as: :json
    end
  end

  test "should clear catalog_skills" do
    skill_name = SkillsConfig.names.first
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", catalog_skills: [ skill_name ])

    patch update_catalog_skills_session_url(session),
          params: { catalog_skills: [] },
          as: :json

    assert_response :success
    session.reload
    assert_equal [], session.catalog_skills
  end

  test "should reject invalid catalog_skills" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", catalog_skills: [])

    patch update_catalog_skills_session_url(session),
          params: { catalog_skills: [ "nonexistent-skill-xyz" ] },
          as: :json

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_includes json_response["error"], "Invalid catalog skills"
  end

  test "should reject non-array catalog_skills" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", catalog_skills: [])

    patch update_catalog_skills_session_url(session),
          params: { catalog_skills: "not-an-array" },
          as: :json

    assert_response :unprocessable_entity
  end

  test "should route to update_catalog_skills" do
    assert_routing(
      { method: :patch, path: "/sessions/1/update_catalog_skills" },
      { controller: "sessions", action: "update_catalog_skills", id: "1" }
    )
  end

  test "show page should load catalog_skills_for_select" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    get session_url(session)
    assert_response :success
    # Verify the available skills data is rendered into the Stimulus controller's data attribute
    assert_select "[data-editable-catalog-skills-available-skills-value]" do |elements|
      available_skills_json = elements.first["data-editable-catalog-skills-available-skills-value"]
      available_skills = JSON.parse(available_skills_json)
      assert available_skills.present?, "Expected available skills to be loaded"
    end
  end

  test "show page should display skills section with edit button" do
    skill_name = SkillsConfig.names.first
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", catalog_skills: [ skill_name ])
    get session_url(session)
    assert_response :success
    assert_select "[data-controller='editable-catalog-skills']"
  end

  test "should reject too many catalog_skills" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt")
    oversized = Array.new(101) { |i| "skill-#{i}" }

    patch update_catalog_skills_session_url(session),
          params: { catalog_skills: oversized },
          as: :json

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_includes json_response["error"], "Too many catalog skills"
  end

  test "show page should display skills edit button even when no skills configured" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test prompt", catalog_skills: [])
    get session_url(session)
    assert_response :success
    # The skills section should appear because @catalog_skills_for_select is loaded on the show page
    assert_select "[data-controller='editable-catalog-skills']"
  end

  # Flat dashboard: archived-session visibility

  test "index hides archived sessions by default" do
    archived = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Archived", status: :archived)
    active = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Active", status: :needs_input)

    get root_url
    assert_response :success

    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(active)}"
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(archived)}", count: 0
  end

  test "index shows archived sessions when the status filter selects them" do
    archived = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Archived", status: :archived)

    get root_url(every_status_params(status: [ "archived" ]))
    assert_response :success

    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(archived)}"
  end

  # The dashboard "View" link is a real <a> to the full session page (so
  # middle-click and the no-JS path work), and carries the SEPARATE drawer path
  # for session-drawer#open to load into the frame. Those two URLs must differ:
  # that is what keeps the frame's URL out of every URL-keyed cache a link can
  # populate.
  test "index View link carries the separate drawer url for the drawer to load" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Drawer link")

    get root_url(every_status_params)
    assert_response :success

    # NOTE: the { count: 1 } equality is required. With the `?` substitution
    # consuming session_path, a trailing bare String would be parsed by
    # assert_select as the expected text content (equality), not as the failure
    # message — so the explicit equality hash keeps the message a message.
    assert_select "a[href=?][data-action*='session-drawer#open'][data-session-drawer-url=?]",
      session_path(session),
      drawer_session_path(session),
      { count: 1 },
      "the dashboard View link must hand session-drawer#open the drawer path, not its own href"
    assert_not_equal session_path(session), drawer_session_path(session),
      "the drawer must load a different URL than any link points at"
  end

  # The structural guarantee, asserted rather than assumed: nothing the dashboard
  # renders links to a drawer path. Turbo's prefetch cache is seeded only by
  # hovering an <a>, so with no anchor pointing at the URL the drawer's frame
  # fetches, there can never be an entry to splice into that fetch. This is the
  # test that would have caught the original bug class, and it keeps catching it
  # no matter which new link to a session someone adds later.
  test "no dashboard link points at a drawer path" do
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Drawer link")

    get root_url(every_status_params)
    assert_response :success

    assert_select "a[href*='/drawer']", false,
      "a link to the drawer path would let Turbo's hover-prefetch cache poison the drawer's own frame fetch"
  end

  # Links rendered INSIDE the drawer (the hierarchy tree) navigate the drawer
  # frame if left alone, and that frame would fetch the frameless /sessions/:id.
  # They target _top and hand the drawer its own path instead.
  test "in-drawer hierarchy links target _top and carry the drawer url" do
    parent = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Parent")
    child = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Child", parent_session_id: parent.id)

    get drawer_session_url(child)
    assert_response :success

    assert_select "a[href=?][data-turbo-frame='_top'][data-session-drawer-url=?]",
      session_path(parent),
      drawer_session_path(parent),
      { count: 1 },
      "a hierarchy link inside the drawer must not frame-navigate to the frameless full-page URL"

    assert_select "a[href*='/drawer']", false,
      "nothing rendered inside the drawer may link to a drawer path — that is the URL its own frame fetches"
  end

  # The other half of the invariant. Keeping the drawer's URL out of every cache a
  # link can seed stops a frameless body being served TO the frame; this stops the
  # frame navigating ITSELF somewhere frameless. A plain same-origin link rendered
  # inside <turbo-frame id="session_detail"> navigates that frame, and every page it
  # could land on — /triggers, /costs, the dashboard, the session's own full page —
  # has no matching frame, so the drawer renders "Content missing" again by a
  # different door. Everything in there must escape to _top.
  #
  # Asserted over the rendered body rather than per-link, so a link added later is
  # caught without anyone remembering this rule.
  test "every same-origin link inside the drawer escapes the frame" do
    parent = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Parent")
    child = Session.create!(
      git_root: "https://github.com/test/repo.git", prompt: "Child",
      parent_session_id: parent.id, scheduling_class: "spot"
    )

    get drawer_session_url(child)
    assert_response :success

    offenders = css_select("a[href]").reject do |link|
      href = link["href"].to_s
      # Only a same-origin path is a frame navigation. An absolute URL, a bare
      # fragment, a mailto:, an explicit target, or data-turbo="false" is not.
      !href.start_with?("/") ||
        link["target"].present? ||
        link["data-turbo"] == "false" ||
        link["data-turbo-frame"] == "_top"
    end.map { |link| "#{link["href"]} (#{link.text.strip[0, 30]})" }

    assert_empty offenders,
      "these links inside the drawer would navigate its Turbo Frame to a page with no " \
      "session_detail frame, rendering \"Content missing\". Give each data-turbo-frame=\"_top\": " \
      "#{offenders.join(", ")}"
  end

  # ---------------------------------------------------------------------------
  # Starred-scoped refresh-all (#refresh_starred)
  # ---------------------------------------------------------------------------

  # The Starred group's Refresh button acts on favorited sessions and nothing else —
  # the core scoping guarantee of the control.
  test "refresh_starred only restarts favorited sessions" do
    Session.where.not(status: :archived).update_all(status: :archived)

    starred_failed = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Starred failed",
      status: :failed,
      session_id: SecureRandom.uuid,
      favorited: true,
      metadata: { "working_directory" => "/tmp/starred" }
    )
    unstarred_failed = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Unstarred failed",
      status: :failed,
      session_id: SecureRandom.uuid,
      favorited: false,
      metadata: { "working_directory" => "/tmp/unstarred" }
    )

    Dir.stubs(:exist?).returns(true)

    post refresh_starred_sessions_url

    assert_redirected_to root_path
    assert_match(/Restarted 1 failed session/, flash[:notice])
    assert_equal "running", starred_failed.reload.status
    assert_equal "failed", unstarred_failed.reload.status
  end

  # Unlike refresh_all, refresh_starred does not skip frozen categories: the Starred
  # group renders every favorited session regardless of category, so the button must
  # act on exactly the cards under it.
  test "refresh_starred includes a starred session in a frozen category" do
    Session.where.not(status: :archived).update_all(status: :archived)

    frozen_cat = Category.create!(name: "frozen cat", is_frozen: true)
    starred_frozen = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Starred in frozen category",
      status: :failed,
      session_id: SecureRandom.uuid,
      favorited: true,
      category: frozen_cat,
      metadata: { "working_directory" => "/tmp/starred-frozen" }
    )

    Dir.stubs(:exist?).returns(true)

    post refresh_starred_sessions_url

    assert_redirected_to root_path
    assert_match(/Restarted 1 failed session/, flash[:notice])
    assert_equal "running", starred_frozen.reload.status
  end

  test "refresh_starred with no starred sessions reports nothing to do" do
    Session.update_all(favorited: false)

    post refresh_starred_sessions_url

    assert_redirected_to root_path
    assert_match(/No non-archived starred sessions to refresh/, flash[:notice])
  end

  test "should route to refresh_starred" do
    assert_routing(
      { method: :post, path: "/sessions/refresh_starred" },
      { controller: "sessions", action: "refresh_starred" }
    )
  end

  # ---------------------------------------------------------------------------
  # Refreshing a waiting session sends the continue nudge
  # ---------------------------------------------------------------------------

  test "refresh of a stalled waiting session sends the continue nudge" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Waiting session",
      status: :waiting,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/waiting" }
    )

    Dir.stubs(:exist?).returns(true)
    AgentSessionJob.expects(:enqueue_with_prompt).with(session.id, AutomatedPrompts::SYSTEM_RECOVERY).once

    post refresh_session_url(session)

    assert_redirected_to session_path(session)
    assert_match(/Continuing waiting session/, flash[:notice])
    assert_equal "running", session.reload.status
  end

  # A waiting session with an unfired one-time wake-up is asleep on purpose. Refreshing
  # it must not fire its work early — it falls through to the plain transcript refresh.
  test "refresh of a waiting session with a pending wake trigger does not nudge it" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Sleeping session",
      status: :needs_input,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/sleeping" }
    )

    # Creating a per-session one-time wake trigger sleeps the session (needs_input -> waiting).
    Trigger.create!(
      name: "Wake session ##{session.id}",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )
    assert_equal "waiting", session.reload.status
    assert session.awaiting_scheduled_wake?, "expected the session to be asleep on a pending wake-up"
    assert_not session.continue_nudge_on_refresh?

    AgentSessionJob.expects(:enqueue_with_prompt).never

    post refresh_session_url(session)

    assert_redirected_to session_path(session)
    assert_equal "waiting", session.reload.status
  end

  # A waiting session that never started has no conversation to continue — the spawn
  # pipeline still owns it, so a nudge would be meaningless.
  test "refresh of a never-started waiting session does not nudge it" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Never started",
      status: :waiting
    )
    assert_nil session.session_id
    assert_not session.continue_nudge_on_refresh?

    AgentSessionJob.expects(:enqueue_with_prompt).never

    post refresh_session_url(session)

    assert_redirected_to session_path(session)
    assert_equal "waiting", session.reload.status
  end

  # The same per-session rule applies to every bulk control, so "refresh all starred"
  # over a mix of statuses does the right thing per session.
  test "refresh_starred continues a stalled waiting session and skips a sleeping one" do
    Session.where.not(status: :archived).update_all(status: :archived)

    stalled = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Starred stalled waiting",
      status: :waiting,
      session_id: SecureRandom.uuid,
      favorited: true,
      metadata: { "working_directory" => "/tmp/stalled" }
    )
    sleeping = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Starred sleeping",
      status: :needs_input,
      session_id: SecureRandom.uuid,
      favorited: true,
      metadata: { "working_directory" => "/tmp/sleeping-bulk", "paused_by" => "user" }
    )
    Trigger.create!(
      name: "Wake session ##{sleeping.id}",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "Wake up",
      reuse_session: true,
      last_session_id: sleeping.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule", configuration: { "scheduled_at" => 1.hour.from_now.iso8601, "timezone" => "UTC" } }
      ]
    )
    assert_equal "waiting", sleeping.reload.status

    Dir.stubs(:exist?).returns(true)
    AgentSessionJob.expects(:enqueue_with_prompt).with(stalled.id, AutomatedPrompts::SYSTEM_RECOVERY).once

    post refresh_starred_sessions_url

    assert_redirected_to root_path
    assert_match(/Continued 1 waiting session/, flash[:notice])
    assert_equal "running", stalled.reload.status
    assert_equal "waiting", sleeping.reload.status
  end

  # ---------------------------------------------------------------------------
  # Per-session refresh icon on the dashboard cards
  # ---------------------------------------------------------------------------

  # Clicking the inline icon comes from the dashboard, so the redirect goes back there
  # rather than yanking the user onto the session detail page.
  test "refresh from the dashboard redirects back to the dashboard" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Waiting session",
      status: :waiting,
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/tmp/waiting-redirect" }
    )

    Dir.stubs(:exist?).returns(true)
    AgentSessionJob.stubs(:enqueue_with_prompt)

    post refresh_session_url(session), headers: { "HTTP_REFERER" => root_url }

    assert_redirected_to root_path
  end

  test "dashboard renders a per-session refresh button for non-running sessions" do
    Session.where.not(status: :archived).update_all(status: :archived)
    Session.update_all(favorited: false)

    waiting = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Waiting card", status: :waiting)
    needs_input = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Needs input card", status: :needs_input)
    failed = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Failed card", status: :failed)
    running = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Running card", status: :running)

    get root_url(every_status_params)
    assert_response :success

    [ waiting, needs_input, failed ].each do |session|
      # Scoped to the session's own card, so this also proves the button lands on the
      # right card rather than merely somewhere on the page.
      assert_select "##{ActionView::RecordIdentifier.dom_id(session)} form[action=?]",
        refresh_session_path(session), { count: 1 },
        "expected an inline refresh button for the #{session.status} session"
      # button_to puts data-* on the submit button, and Turbo reads the frame target
      # from the submitter — this is what breaks the redirect out of the card's frame
      # instead of swapping a full page into it.
      assert_select "##{ActionView::RecordIdentifier.dom_id(session)} form[action=?] button[data-turbo-frame=?]",
        refresh_session_path(session), "_top", { count: 1 },
        "the refresh button must target _top so the redirect is not swapped into the card frame"
    end

    # Prove the running card is on the page BEFORE asserting its button is absent —
    # otherwise a scoping/pagination change that drops running cards entirely would
    # keep this green while the feature is broken.
    assert_select "##{ActionView::RecordIdentifier.dom_id(running)}", { count: 1 },
      "the running session's card must be rendered for the absence assertion below to mean anything"
    assert_select "form[action=?]", refresh_session_path(running), { count: 0 },
      "a running session must not get an inline refresh button"
  end

  test "starred group renders its own refresh-all control" do
    Session.where.not(status: :archived).update_all(status: :archived)
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Starred card", status: :waiting, favorited: true)

    get root_url(every_status_params)
    assert_response :success

    assert_select "#pinned_section form[action=?]", refresh_starred_sessions_path, { count: 1 },
      "the Starred group needs its own refresh-all button"
  end

  private

  # Both Quick Router entry points resolve the router root and enqueue a job.
  # Stub the pair so a test can assert on the created row alone.
  def stub_router_agent_root
    AgentRootsConfig.stubs(:find!).with(AgentRootsConfig.router_root_name).returns(
      OpenStruct.new(
        url: "https://github.com/test/repo.git",
        default_branch: "main",
        subdirectory: "agent-roots/zimmer-orchestrator",
        default_mcp_servers: []
      )
    )
    AgentSessionJob.stubs(:enqueue_new_session)
  end
end
