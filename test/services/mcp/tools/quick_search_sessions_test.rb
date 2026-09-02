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

  test "the tool description no longer claims to search titles only" do
    description = Mcp::Tools::QuickSearchSessions.rendered_description

    assert_not_includes description, "This tool only searches session titles"
    assert_not_includes description, "titles only"
    assert_includes description, "search_contents"
    # #683: the description also has to stop implying `query` is title-only, since it
    # has always reached metadata and custom_metadata as well.
    assert_includes description, "custom_metadata"
  end

  # --- #683: the schema has to carry what an agent needs to deduplicate correctly ---
  #
  # An agent reads the tool's own schema, never this file. Two operational facts
  # decide whether a duplicate-check finds anything: the show_archived default hides
  # the sessions that already finished the work, and the prompt line in each result
  # is a leading prefix that cuts an artifact URL off. Pin the words, not just the
  # behaviour, because a description-only fix is exactly the kind that rots back.

  def schema_property(name)
    Mcp::Tools::QuickSearchSessions.input_schema.to_h.dig(:properties, name)
  end

  test "the description says a duplicate-check needs show_archived, and why" do
    description = Mcp::Tools::QuickSearchSessions.rendered_description

    assert_includes description, "**`show_archived` defaults to false, and that default hides finished work.**"
    assert_includes description, "Agents archive themselves when they run to completion"
    assert_includes description, "with `show_archived: true`",
      "expected the duplicate-check use case to spell out the flag it needs"

    show_archived = schema_property(:show_archived)[:description]
    assert_includes show_archived, "Default: false"
    assert_includes show_archived, "a session that completed its task has archived itself"
    assert_includes show_archived, "Pass true whenever you are checking whether something has already been done"
    assert_includes show_archived, %(Naming "archived" in status also includes them)
  end

  test "the description says the prompt line is a truncated leading prefix" do
    description = Mcp::Tools::QuickSearchSessions.rendered_description

    assert_includes description, "its first #{Mcp::Tools::QuickSearchSessions::MAX_PROMPT_DISPLAY_LENGTH} characters, then `...`"
    assert_includes description, "That is a leading prefix — not a summary, and not the part that matched"
    assert_includes description, "call `get_session` for the whole prompt"
  end

  # The description must match the SQL exactly: METADATA_PREDICATE reads title,
  # metadata and custom_metadata and nothing else. Claiming the prompt is searched
  # would be worse than the understatement this issue was filed about.
  test "the query description matches METADATA_PREDICATE, prompt column excluded" do
    query = schema_property(:query)[:description]

    assert_includes query, "the session title and the metadata/custom_metadata JSON"
    assert_includes query, "Does not read the prompt column"
    assert_includes query, "search_contents: true to match transcript text too"

    %w[title metadata custom_metadata].each do |column|
      assert_includes SessionSearchable::METADATA_PREDICATE, "#{column}"
    end
    assert_not_includes SessionSearchable::METADATA_PREDICATE, "prompt"
  end

  test "query reaches custom_metadata, so an archived session is found by the artifact it worked" do
    finished = Session.create!(
      title: "Fix good-eggs login flake", prompt: "prompt", git_root: "https://github.com/test/repo.git",
      agent_runtime: "claude_code", status: :archived,
      custom_metadata: { "issue" => "https://github.com/tadasant/strad/issues/195" }
    )

    assert_equal "No sessions found matching the specified criteria.", @tool.call("query" => "strad/issues/195"),
      "the default search must hide the archived session — that is the trap the description now names"

    output = @tool.call("query" => "strad/issues/195", "show_archived" => true)

    assert_includes output, "### Fix good-eggs login flake (ID: #{finished.id})",
      "the title carries no '195'; only custom_metadata does"
  end

  test "query does not read the prompt column, and search_contents cannot see an unstarted prompt either" do
    Session.create!(
      title: "Nondescript title", prompt: "Please fix https://github.com/tadasant/strad/issues/195 today",
      git_root: "https://github.com/test/repo.git", agent_runtime: "claude_code", status: :waiting
    )

    assert_equal "No sessions found matching the specified criteria.",
      @tool.call("query" => "strad/issues/195", "show_archived" => true)

    with_contents = @tool.call("query" => "strad/issues/195", "show_archived" => true, "search_contents" => true)
    assert_includes with_contents, "No sessions matched",
      "a waiting session has no transcript, so the prompt is not reachable that way yet"
  end

  test "the prompt preview is a leading prefix, so an artifact named late in the prompt is invisible in it" do
    session = sessions(:running)
    session.update!(prompt: "#{'Two sentences of context first. ' * 4}Then https://github.com/tadasant/strad/issues/195")

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Prompt:** #{session.prompt[0, 100]}..."
    assert_not_includes output, "issues/195"
  end

  test "prompt preview is truncated" do
    session = sessions(:running)
    session.update!(prompt: "x" * 150)

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Prompt:** #{'x' * 100}..."
  end
end
