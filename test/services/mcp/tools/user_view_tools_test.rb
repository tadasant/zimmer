# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# `get_user_view` and `reorder_user_view` — the read and write halves of the
# dashboard's User view over MCP, which is how the Reprioritize button's session
# reaches the board without scraping the page.
class Mcp::Tools::UserViewToolsTest < ActiveSupport::TestCase
  GREEN_PR = "https://github.com/o/r/pull/42"

  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.delete_all

    @read = Mcp::Tools::GetUserView.new(context: Mcp::Context.new(tool_groups: "sessions"))
    @write = Mcp::Tools::ReorderUserView.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  def make_session(status: :needs_input, klass: SessionGenesis::SPOT, precedence: 0, title: "A session", custom_metadata: {})
    Session.create!(
      git_root: "https://github.com/test/repo.git", prompt: "p", title: title,
      status: status, scheduling_class: klass, precedence: precedence,
      custom_metadata: custom_metadata
    )
  end

  # ---- The read --------------------------------------------------------------

  test "an empty board says so rather than returning an empty list" do
    assert_includes @read.call({}), "the board is empty"
  end

  test "rows come back in the board's own order, priority above spot" do
    spot = make_session(klass: SessionGenesis::SPOT, precedence: 100_000, title: "spot high")
    priority = make_session(klass: SessionGenesis::PRIORITY, precedence: 1, title: "priority low")

    output = @read.call({})

    assert_operator output.index("priority low"), :<, output.index("spot high"),
      "a spot session cannot outrank a priority one however high its precedence"
    assert_includes output, "1. priority low (ID: #{priority.id})"
    assert_includes output, "2. spot high (ID: #{spot.id})"
  end

  # The three facts a decision on this board turns on that a plain session
  # listing does not carry.
  test "a row carries the agent root, the generated status and the PR with its CI verdict" do
    session = make_session(custom_metadata: {
      "github_pull_request_urls" => [ GREEN_PR ],
      "github_pull_request_statuses" => { GREEN_PR => "open" },
      "github_pull_request_ci_statuses" => { GREEN_PR => "pass" }
    })
    session.update!(metadata: (session.metadata || {}).merge("agent_root_key" => "zimmer"))
    SessionStatusSummary.create!(session: session, state: "ready",
      summary: "Holding the PR for a merge decision.", transcript_line_count: session.transcript_line_count)

    output = @read.call({})

    assert_includes output, "- **Agent root:** zimmer"
    assert_includes output, GREEN_PR
    assert_includes output, "CI pass"
    assert_includes output, "Holding the PR for a merge decision."
    assert_match(/\*\*Mergeable:\*\* yes/, output)
  end

  # A row the human has already actioned is not an outstanding decision, and a
  # reprioritizing session that could not tell would keep ranking it as one.
  test "a row the human has already pressed Merge on says so" do
    session = make_session(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ GREEN_PR ],
      "github_pull_request_statuses" => { GREEN_PR => "open" },
      "github_pull_request_ci_statuses" => { GREEN_PR => "pass" }
    })
    Sessions::AuthorizeMerge.call(session: session)

    output = @read.call("status" => [ "running" ])

    assert_match(/\*\*Merge already authorized\*\*/, output)
  end

  # There is no tool for PRESSING that button, and that is the design rather than
  # an omission: what sanctions an agent merging its own work is that a human
  # clicked it.
  test "no tool in any group can authorize a merge" do
    all = Mcp::Registry::ALL_TOOLS.map { |d| d.klass }

    assert_empty all.grep(/AuthorizeMerge|Merge/),
      "the Merge button must stay browser-only — an MCP tool for it would let an agent authorize its own merge"
  end

  test "a row whose PR is not green says why it is not mergeable" do
    make_session(custom_metadata: {
      "github_pull_request_urls" => [ GREEN_PR ],
      "github_pull_request_statuses" => { GREEN_PR => "open" },
      "github_pull_request_ci_statuses" => { GREEN_PR => "pending" }
    })

    assert_match(/\*\*Mergeable:\*\* no — CI is pending/, @read.call({}))
  end

  test "the default filter is the board's own: needs_input, on board" do
    parked = make_session(status: :needs_input, title: "parked")
    make_session(status: :running, title: "running")

    output = @read.call({})

    assert_includes output, "parked"
    assert_not_includes output, "(ID: #{Session.find_by(title: 'running').id})"
    assert_includes output, "1 row(s)"
    assert_includes output, "(ID: #{parked.id})"
  end

  # An ABSENT status filter takes the board's default; an explicitly EMPTY one is
  # "every status". Those are different requests, exactly as the dashboard's own
  # Filters form treats them.
  test "an explicitly empty status list widens to every status" do
    make_session(status: :needs_input, title: "parked")
    make_session(status: :running, title: "running one")

    output = @read.call("status" => [])

    assert_includes output, "parked"
    assert_includes output, "running one"
  end

  test "summary_chars 0 drops the blurb, which is how a large board is paged cheaply" do
    session = make_session
    SessionStatusSummary.create!(session: session, state: "ready", summary: "A long blurb.",
      transcript_line_count: session.transcript_line_count)

    assert_not_includes @read.call("summary_chars" => 0), "A long blurb."
    assert_includes @read.call({}), "A long blurb."
  end

  test "pagination reports how far through the board a page is" do
    3.times { |i| make_session(precedence: 10 - i, title: "row #{i}") }

    first = @read.call("per_page" => 2)

    assert_includes first, "page 1 of 2"
    assert_includes first, "Use page=2"
    assert_includes @read.call("per_page" => 2, "page" => 2), "page 2 of 2"
  end

  # ---- The write -------------------------------------------------------------

  test "an ordering is applied top first and reported back" do
    a = make_session(precedence: 1, title: "a")
    b = make_session(precedence: 2, title: "b")

    output = @write.call("session_ids" => [ a.id, b.id ])

    assert_includes output, "Board reordered"
    assert_includes output, "1. Session #{a.id}"
    assert_equal [ a.id, b.id ], Session.ranked.pluck(:id)
  end

  test "the reason reaches the sessions' logs, so the human can see what moved their board" do
    a = make_session(precedence: 1)

    @write.call("session_ids" => [ a.id ], "reason" => "unblocks three sessions")

    assert_match(/unblocks three sessions/, a.logs.last.content)
  end

  test "an unknown id is a tool error naming the id, and nothing is written" do
    a = make_session(precedence: 1)

    error = assert_raises(Mcp::ToolError) { @write.call("session_ids" => [ a.id, 999_999_999 ]) }

    assert_match(/999999999/, error.message)
    assert_equal 1, a.reload.precedence
  end

  test "a non-array argument is refused rather than coerced" do
    assert_raises(Mcp::ToolError) { @write.call("session_ids" => 7) }
  end

  # ---- Registration ----------------------------------------------------------

  # `zimmer-sessions` is the catalog server the reprioritizer root attaches, and
  # it is scoped to the `sessions` group — so both tools have to live there or
  # the button's session cannot reach the board at all.
  test "both tools are in the sessions group" do
    names = Mcp::Registry.tools_for(%w[sessions]).map(&:tool_name)

    assert_includes names, "get_user_view"
    assert_includes names, "reorder_user_view"
  end

  test "the readonly variant of the sessions group offers the read and not the write" do
    names = Mcp::Registry.tools_for(%w[sessions_readonly]).map(&:tool_name)

    assert_includes names, "get_user_view"
    assert_not_includes names, "reorder_user_view"
  end
end
