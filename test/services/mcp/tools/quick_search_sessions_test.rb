# frozen_string_literal: true

require "test_helper"


class Mcp::Tools::QuickSearchSessionsTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::QuickSearchSessions.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  def create_transcript_session(title:, said:, created_at: Time.current)
    Session.create!(
      title: title, prompt: "prompt", git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code", status: :needs_input, created_at: created_at,
      transcript: [ { "type" => "assistant", "message" => { "role" => "assistant", "content" => said } } ]
    )
  end

  test "id returns the single matching session" do
    session = sessions(:router_child_running)

    output = @tool.call("id" => session.id)

    assert_includes output, "## Session Found"
    assert_includes output, "### Configure Hatchbox deployment (ID: #{session.id})"
    assert_includes output, "- **Status:** running"
    assert_includes output, "- **Agent Runtime:** claude_code"
  end

  test "unknown id raises a tool error" do
    error = assert_raises(Mcp::ToolError) { @tool.call("id" => 999_999) }
    assert_match(/Session not found/, error.message)
  end

  test "query matches on title" do
    output = @tool.call("query" => "Configure Hatchbox deployment")

    assert_includes output, "## Agent Sessions"
    assert_includes output, "Found 1 session(s) (page 1 of 1):"
    assert_includes output, "### Configure Hatchbox deployment (ID: #{sessions(:router_child_running).id})"
  end

  test "archived sessions are excluded unless show_archived" do
    assert_equal "No sessions found matching the specified criteria.",
      @tool.call("query" => "Research deployment options")

    output = @tool.call("query" => "Research deployment options", "show_archived" => true)
    assert_includes output, "### Research deployment options (ID: #{sessions(:router_child_archived).id})"
  end

  # Parity with the dashboard's status multi-select: an agent must be able to ask the
  # same "any of these statuses" question a human can tick in the Filters section.
  test "status accepts an array and matches any of them" do
    running = sessions(:router_child_running)
    needs_input = sessions(:needs_input)

    output = @tool.call("status" => [ "running", "needs_input" ], "per_page" => 100)

    assert_includes output, "(ID: #{running.id})"
    assert_includes output, "(ID: #{needs_input.id})"
    assert_not_includes output, "(ID: #{sessions(:waiting).id})"
  end

  test "naming archived in the status filter is enough to see archived sessions" do
    archived = sessions(:router_child_archived)

    output = @tool.call("status" => "archived", "per_page" => 100)

    assert_includes output, "(ID: #{archived.id})"
  end

  test "an invalid status inside the array is rejected" do
    error = assert_raises(Mcp::ToolError) { @tool.call("status" => [ "running", "chartreuse" ]) }
    assert_match(/Invalid status: chartreuse/, error.message)
  end

  test "status filter and pagination footer" do
    output = @tool.call("status" => "running", "per_page" => 1)

    assert_includes output, "- **Status:** running"
    assert_includes output, "*More sessions available. Use page=2 to see the next page.*"
  end

  test "invalid status raises a tool error" do
    error = assert_raises(Mcp::ToolError) { @tool.call("status" => "bogus") }
    assert_match(/Invalid status/, error.message)
  end

  # --- transcript content search (#714 gap 2) ---

  test "search_contents finds a session by a phrase only its transcript carries" do
    target = create_transcript_session(title: "Nondescript title", said: "the kestrel manoeuvre worked")

    without = @tool.call("query" => "kestrel manoeuvre")
    assert_equal "No sessions found matching the specified criteria.", without,
      "title/metadata search must not see transcript text"

    output = @tool.call("query" => "kestrel manoeuvre", "search_contents" => true)

    assert_includes output, "## Agent Sessions (transcript search)"
    assert_includes output, "### Nondescript title (ID: #{target.id})"
    assert_includes output, "Scan complete"
  end

  test "search_contents remains a superset of the title search" do
    output = @tool.call("query" => "Configure Hatchbox deployment", "search_contents" => true)

    assert_includes output, "### Configure Hatchbox deployment (ID: #{sessions(:router_child_running).id})"
  end

  test "a content search that stops early says so and hands back a cursor" do
    newer = create_transcript_session(title: "Newer", said: "shared phrase here", created_at: 1.hour.ago)
    older = create_transcript_session(title: "Older", said: "shared phrase here", created_at: 2.hours.ago)

    output = @tool.call("query" => "shared phrase here", "search_contents" => true, "per_page" => 1)

    assert_includes output, "(ID: #{newer.id})"
    assert_not_includes output, "(ID: #{older.id})"
    assert_includes output, "Scan incomplete"
    assert_match(/scan_cursor="[^"]+"/, output)

    cursor = output[/scan_cursor="([^"]+)"/, 1]
    resumed = @tool.call(
      "query" => "shared phrase here", "search_contents" => true, "per_page" => 25, "scan_cursor" => cursor
    )

    assert_includes resumed, "(ID: #{older.id})"
    assert_not_includes resumed, "(ID: #{newer.id})"
  end

  test "a content search with no matches says the scan was complete rather than just empty" do
    output = @tool.call("query" => "no session ever said this", "search_contents" => true)

    assert_includes output, "No sessions matched"
    assert_includes output, "Scan complete"
  end

  test "search_contents is ignored without a query, and pagination still applies" do
    output = @tool.call("search_contents" => true, "status" => "running", "per_page" => 1)

    assert_includes output, "## Agent Sessions"
    assert_not_includes output, "(transcript search)"
  end

  test "an over-long query is rejected on the content path too" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("query" => "x" * 1001, "search_contents" => true)
    end
    assert_match(/Query too long/, error.message)
  end

  # #683: `query` reaches metadata and custom_metadata, which is where a router-spawned
  # session carries the issue it is working — so an agent that searches by the issue's
  # identifier gets an exact duplicate check. It does NOT reach the prompt column, and
  # the description must not suggest it does.
  test "query matches custom_metadata but not the prompt" do
    session = Session.create!(
      title: "Fix the login timeout", prompt: "Context first. Then: work https://github.com/test/repo/issues/9876",
      git_root: "https://github.com/test/repo.git", agent_runtime: "claude_code", status: :needs_input,
      custom_metadata: { "tracking_issue" => "https://github.com/test/repo/issues/4321" }
    )

    output = @tool.call("query" => "repo/issues/4321")
    assert_includes output, "(ID: #{session.id})"

    assert_equal "No sessions found matching the specified criteria.", @tool.call("query" => "repo/issues/9876")
  end

  test "the tool description no longer claims to search titles only" do
    description = Mcp::Tools::QuickSearchSessions.rendered_description

    assert_not_includes description, "This tool only searches session titles"
    assert_includes description, "search_contents"
    # #683: the description also has to stop implying `query` is title-only, since it
    # has always reached metadata and custom_metadata as well.
    assert_includes description, "custom_metadata"
    assert_includes description, "`query` never reads the prompt column"
  end

  # #683: the two facts an agent needs to deduplicate correctly, stated where the agent
  # reads them — in the tool's own schema, not in the source or the catalog prose.
  test "show_archived's description says the default hides finished work" do
    schema = Mcp::Tools::QuickSearchSessions.input_schema.to_h.deep_symbolize_keys

    show_archived = schema.dig(:properties, :show_archived, :description)
    assert_includes show_archived, "Default: false"
    assert_includes show_archived, "a session that finished a piece of work has archived itself"
    assert_includes show_archived, "sets this true"
    assert_includes show_archived, 'names "archived" in status, which includes them too'

    query = schema.dig(:properties, :query, :description)
    assert_includes query, "metadata/custom_metadata JSON"
    assert_includes query, "not against the prompt"

    description = Mcp::Tools::QuickSearchSessions.rendered_description
    assert_includes description, "show_archived: true"
  end

  test "the description says the prompt preview is a leading prefix of a fixed length" do
    description = Mcp::Tools::QuickSearchSessions.rendered_description
    length = Mcp::Tools::QuickSearchSessions::MAX_PROMPT_DISPLAY_LENGTH

    assert_includes description, "a leading prefix of the prompt"
    assert_includes description, "an identifier named later in the prompt is not shown"
    assert_includes description, "the first #{length} characters of the prompt, then `...`"
  end

  test "prompt preview is truncated to the documented leading prefix" do
    session = sessions(:running)
    length = Mcp::Tools::QuickSearchSessions::MAX_PROMPT_DISPLAY_LENGTH
    # An identifier past the prefix is exactly what the description warns is not shown.
    session.update!(prompt: "#{'x' * length}https://github.com/test/repo/issues/4321")

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Prompt:** #{'x' * length}..."
    assert_not_includes output, "issues/4321"
  end
end
