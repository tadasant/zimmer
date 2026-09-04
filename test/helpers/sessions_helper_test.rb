require "test_helper"

class SessionsHelperTest < ActionView::TestCase
  # Tests for goal_display_name
  test "goal_display_name returns name when matching by description" do
    conditions = [
      { id: "e2e-verified-green-pr", name: "E2E Verified Green PR", description: "Full description text" }
    ]
    assert_equal "E2E Verified Green PR", goal_display_name("Full description text", conditions)
  end

  test "goal_display_name returns name when matching by ID" do
    conditions = [
      { id: "e2e-verified-green-pr", name: "E2E Verified Green PR", description: "Full description text" }
    ]
    assert_equal "E2E Verified Green PR", goal_display_name("e2e-verified-green-pr", conditions)
  end

  test "goal_display_name returns Custom for unrecognized value" do
    conditions = [
      { id: "e2e-verified-green-pr", name: "E2E Verified Green PR", description: "Full description text" }
    ]
    assert_equal "Custom", goal_display_name("something completely different", conditions)
  end

  test "goal_display_name returns nil for blank value" do
    conditions = [
      { id: "e2e-verified-green-pr", name: "E2E Verified Green PR", description: "Full description text" }
    ]
    assert_nil goal_display_name("", conditions)
    assert_nil goal_display_name(nil, conditions)
  end

  test "goal_display_name handles nil conditions list" do
    assert_equal "Custom", goal_display_name("some value", nil)
  end

  # Tests for ci_status_color_class
  test "ci_status_color_class returns green for pass" do
    assert_equal "text-green-500", ci_status_color_class("pass")
  end

  test "ci_status_color_class returns red for fail" do
    assert_equal "text-red-500", ci_status_color_class("fail")
  end

  test "ci_status_color_class returns yellow for pending" do
    assert_equal "text-yellow-500", ci_status_color_class("pending")
  end

  test "ci_status_color_class returns gray for cancel" do
    assert_equal "text-gray-400", ci_status_color_class("cancel")
  end

  test "ci_status_color_class returns gray for skipping" do
    assert_equal "text-gray-400", ci_status_color_class("skipping")
  end

  test "ci_status_color_class returns light gray for nil" do
    assert_equal "text-gray-300", ci_status_color_class(nil)
  end

  test "ci_status_color_class returns light gray for unknown status" do
    assert_equal "text-gray-300", ci_status_color_class("unknown")
  end

  # Tests for ci_status_bg_class
  test "ci_status_bg_class returns green background for pass" do
    assert_equal "bg-green-500", ci_status_bg_class("pass")
  end

  test "ci_status_bg_class returns red background for fail" do
    assert_equal "bg-red-500", ci_status_bg_class("fail")
  end

  test "ci_status_bg_class returns yellow background for pending" do
    assert_equal "bg-yellow-500", ci_status_bg_class("pending")
  end

  test "ci_status_bg_class returns gray background for cancel" do
    assert_equal "bg-gray-400", ci_status_bg_class("cancel")
  end

  test "ci_status_bg_class returns gray background for skipping" do
    assert_equal "bg-gray-400", ci_status_bg_class("skipping")
  end

  test "ci_status_bg_class returns light gray background for nil" do
    assert_equal "bg-gray-300", ci_status_bg_class(nil)
  end

  # ---------------------------------------------------------------------------
  # OpenTranscripts display helpers (ot_*)
  # ---------------------------------------------------------------------------
  Types = OpenTranscript::Types

  def event(type, **fields)
    OpenTranscript.event(
      type: type, id: "e1", parent_id: nil, ts: "2025-11-20T10:00:00Z",
      sort_time: Time.parse("2025-11-20T10:00:00Z"), **fields
    )
  end

  # === ot_event_label ===

  test "ot_event_label labels each event type" do
    assert_equal "User", ot_event_label(event(Types::USER_MESSAGE))
    assert_equal "Assistant", ot_event_label(event(Types::ASSISTANT_MESSAGE))
    assert_equal "Thinking", ot_event_label(event(Types::THINKING))
    assert_equal "Tool: Bash", ot_event_label(event(Types::TOOL_CALL, tool_name: "Bash"))
    assert_equal "Tool: unknown", ot_event_label(event(Types::TOOL_CALL, tool_name: nil))
    assert_equal "Tool Result", ot_event_label(event(Types::TOOL_RESULT, is_error: false))
    assert_equal "Tool Result (Error)", ot_event_label(event(Types::TOOL_RESULT, is_error: true))
    assert_equal "Subagent", ot_event_label(event(Types::SUBAGENT_SPAWN))
    assert_equal "Compaction", ot_event_label(event(Types::COMPACTION))
    assert_equal "Error", ot_event_label(event(Types::ERROR))
    assert_equal "Queue Event", ot_event_label(event(Types::SYSTEM_EVENT, subtype: "queue-operation"))
    assert_equal "Git Status", ot_event_label(event(Types::SYSTEM_EVENT, subtype: "git_status"))
  end

  # === runtime notices (#488) ===
  #
  # A line the CLI wrote into its own transcript wearing a user role must not
  # read as "User" anywhere in the header.

  RUNTIME_MARKERS = {
    "interruptedByShutdown" => "the CLI was shut down mid-turn",
    "isMeta" => "CLI-internal scaffolding"
  }.freeze

  def markers_for(flags)
    flags&.map { |flag| { "flag" => flag, "reason" => RUNTIME_MARKERS[flag] } }
  end

  def runtime_notice(text: "[Request interrupted by user for tool use]", markers: [ "interruptedByShutdown" ])
    markers = markers_for(markers)
    event(
      Types::SYSTEM_EVENT,
      subtype: OpenTranscript::SystemEventSubtypes::RUNTIME_NOTICE,
      payload: { "text" => text, "markers" => markers }
    )
  end

  test "ot_event_label labels a runtime notice distinctly from a user turn" do
    assert_equal "Runtime Notice", ot_event_label(runtime_notice)
    refute_equal ot_event_label(event(Types::USER_MESSAGE)), ot_event_label(runtime_notice)
  end

  test "ot_icon_kind gives a runtime notice the system glyph, not the user glyph" do
    assert_equal :system, ot_icon_kind(runtime_notice)
    assert_equal "bg-cyan-100", ot_badge_class(runtime_notice)
    assert_equal "text-cyan-600", ot_icon_color(runtime_notice)
  end

  test "ot_runtime_notice? is true only for the runtime-notice subtype" do
    assert ot_runtime_notice?(runtime_notice)
    refute ot_runtime_notice?(event(Types::SYSTEM_EVENT, subtype: "queue-operation"))
    refute ot_runtime_notice?(event(Types::USER_MESSAGE))
    # A UserMessage that somehow carries the subtype is still a user message.
    refute ot_runtime_notice?(event(Types::USER_MESSAGE, subtype: OpenTranscript::SystemEventSubtypes::RUNTIME_NOTICE))
  end

  test "ot_content_markdown states who wrote a runtime notice above its text" do
    body = ot_content_markdown(runtime_notice)

    assert_includes body, "not typed by a person"
    assert_includes body, "the CLI was shut down mid-turn (`interruptedByShutdown`)"
    assert_includes body, "[Request interrupted by user for tool use]"
  end

  test "ot_content_markdown names both markers when a notice carries both" do
    body = ot_content_markdown(runtime_notice(markers: %w[interruptedByShutdown isMeta]))

    assert_includes body, "the CLI was shut down mid-turn (`interruptedByShutdown`)"
    assert_includes body, "CLI-internal scaffolding (`isMeta`)"
  end

  test "ot_content_markdown still attributes a runtime notice with no usable payload" do
    assert_includes ot_content_markdown(runtime_notice(markers: nil)), "not typed by a person"
    assert_includes ot_content_markdown(event(Types::SYSTEM_EVENT, subtype: OpenTranscript::SystemEventSubtypes::RUNTIME_NOTICE)),
      "not typed by a person"
  end

  # === collapsing an injected skill dump ===
  #
  # The `isMeta` flag carries both an entire SKILL.md and one-line CLI
  # scaffolding. Only the first is worth folding away.

  SKILL_DUMP = <<~TEXT
    Base directory for this skill: /home/rails/clone/.claude/skills/update-skill

    # Update Skill

    #{'Body line that pads this out past the threshold. ' * 60}
  TEXT

  test "ot_runtime_notice_digest names the skill an injected SKILL.md came from" do
    digest = ot_runtime_notice_digest(runtime_notice(text: SKILL_DUMP, markers: [ "isMeta" ]))

    assert_equal "update-skill", digest[:label]
    assert_match(/\Aapprox\. \d+(\.\d)?k? tokens\z/, digest[:token_summary])
  end

  test "ot_runtime_notice_digest estimates tokens from the character count" do
    # 4 characters per token: 8_000 characters reads as approximately 2.0k.
    text = "Base directory for this skill: /skills/big\n#{'x' * 7_957}"
    assert_equal 8_000, text.length

    assert_equal "approx. 2.0k tokens", ot_runtime_notice_digest(runtime_notice(text: text))[:token_summary]
  end

  test "ot_runtime_notice_digest leaves a short runtime notice uncollapsed" do
    assert_nil ot_runtime_notice_digest(runtime_notice(text: "Continue from where you left off.", markers: [ "isMeta" ]))
    assert_nil ot_runtime_notice_digest(runtime_notice)
    assert_nil ot_runtime_notice_digest(runtime_notice(text: "a" * SessionsHelper::RUNTIME_NOTICE_COLLAPSE_CHARS))
  end

  test "ot_runtime_notice_digest leaves a short skill dump uncollapsed too" do
    short = "Base directory for this skill: /skills/tiny\n\n# Tiny\n\nOne line of body."
    assert_nil ot_runtime_notice_digest(runtime_notice(text: short))

    # And the floor is what stops it, not the skill trigger: pad past the floor
    # and the same shape collapses under its skill name.
    padded = "#{short}\n#{'padding. ' * 60}"
    assert_operator padded.length, :>, SessionsHelper::RUNTIME_NOTICE_FLOOR_CHARS
    assert_equal "tiny", ot_runtime_notice_digest(runtime_notice(text: padded))[:label]
  end

  test "ot_runtime_notice_digest refuses a base directory that names no skill" do
    %w[. ..].each do |basename|
      text = "Base directory for this skill: /home/agent/skills/#{basename}\n#{'x' * 3_000}"

      # Falls back to the first line rather than heading the row with "." or "..".
      assert_equal "Base directory for this skill: /home/agent/skills/#{basename}",
        ot_runtime_notice_digest(runtime_notice(text: text))[:label]
    end
  end

  test "ot_runtime_notice_digest collapses a large notice that is not a skill dump, labelled by its first line" do
    text = "The coordinator sent a message while you were working:\n\n#{'detail ' * 500}"
    digest = ot_runtime_notice_digest(runtime_notice(text: text))

    assert_equal "The coordinator sent a message while you were working:", digest[:label]
  end

  test "ot_runtime_notice_digest falls back to a generic label when there is no readable first line" do
    assert_equal "Injected context", ot_runtime_notice_digest(runtime_notice(text: "\n \n#{' ' * 3_000}"))[:label]
  end

  test "ot_runtime_notice_digest ignores a skill header that is not at the start of the text" do
    text = "Some other injected block.\nBase directory for this skill: /skills/update-skill\n#{'x' * 3_000}"

    assert_equal "Some other injected block.", ot_runtime_notice_digest(runtime_notice(text: text))[:label]
  end

  test "ot_runtime_notice_digest is nil for anything that is not a runtime notice" do
    assert_nil ot_runtime_notice_digest(event(Types::USER_MESSAGE, content: [ { "type" => "text", "text" => "x" * 5_000 } ]))
    assert_nil ot_runtime_notice_digest(event(Types::SYSTEM_EVENT, subtype: "queue-operation"))
  end

  test "ot_content_markdown leaves other system events on the generic renderer" do
    item = event(Types::SYSTEM_EVENT, subtype: "queue-operation", payload: { "operation" => "dequeue" })

    assert_includes ot_content_markdown(item), "**Operation:** Dequeue"
    refute_includes ot_content_markdown(item), "not typed by a person"
  end

  # === ot_icon_kind / badge / color ===

  test "ot_icon_kind maps event type to a glyph" do
    assert_equal :user, ot_icon_kind(event(Types::USER_MESSAGE))
    assert_equal :assistant, ot_icon_kind(event(Types::ASSISTANT_MESSAGE))
    assert_equal :thinking, ot_icon_kind(event(Types::THINKING))
    assert_equal :tool, ot_icon_kind(event(Types::TOOL_CALL))
    assert_equal :tool, ot_icon_kind(event(Types::SUBAGENT_SPAWN))
    assert_equal :error, ot_icon_kind(event(Types::ERROR))
    assert_equal :system, ot_icon_kind(event(Types::SYSTEM_EVENT))
  end

  test "ot_badge_class and ot_icon_color follow icon kind" do
    assert_equal "bg-indigo-100", ot_badge_class(event(Types::USER_MESSAGE))
    assert_equal "bg-green-100", ot_badge_class(event(Types::ASSISTANT_MESSAGE))
    assert_equal "bg-purple-100", ot_badge_class(event(Types::TOOL_CALL))
    assert_equal "text-indigo-600", ot_icon_color(event(Types::USER_MESSAGE))
    assert_equal "text-red-600", ot_icon_color(event(Types::ERROR))
  end

  # === ot_tool_row? ===

  test "ot_tool_row? is true for tool-ish events and false for messages" do
    assert ot_tool_row?(event(Types::THINKING))
    assert ot_tool_row?(event(Types::TOOL_CALL))
    assert ot_tool_row?(event(Types::TOOL_RESULT))
    assert ot_tool_row?(event(Types::SUBAGENT_SPAWN))
    refute ot_tool_row?(event(Types::USER_MESSAGE))
    refute ot_tool_row?(event(Types::ASSISTANT_MESSAGE))
  end

  # === ot_image_count ===

  test "ot_image_count counts image parts in message content" do
    item = event(Types::USER_MESSAGE, content: [
      OpenTranscript.text_part("hi"),
      OpenTranscript.image_part(data: "AAAA", mime_type: "image/png"),
      OpenTranscript.image_part(data: "BBBB", mime_type: "image/png")
    ])
    assert_equal 2, ot_image_count(item)
  end

  test "ot_image_count is zero when content has no images or is not an array" do
    assert_equal 0, ot_image_count(event(Types::USER_MESSAGE, content: [ OpenTranscript.text_part("hi") ]))
    assert_equal 0, ot_image_count(event(Types::THINKING, text: "x"))
  end

  # === ot_content_markdown ===

  test "ot_content_markdown renders message text parts" do
    item = event(Types::ASSISTANT_MESSAGE, content: [ OpenTranscript.text_part("Hello"), OpenTranscript.text_part("World") ])
    assert_equal "Hello\n\nWorld", ot_content_markdown(item)
  end

  test "ot_content_markdown renders an image placeholder" do
    item = event(Types::USER_MESSAGE, content: [ OpenTranscript.image_part(data: "AAAA", mime_type: "image/png") ])
    assert_equal "[Image attached: PNG]", ot_content_markdown(item)
  end

  test "ot_content_markdown renders Thinking text" do
    assert_equal "let me reason", ot_content_markdown(event(Types::THINKING, text: "let me reason"))
  end

  test "ot_content_markdown renders a tool call with parameters" do
    item = event(Types::TOOL_CALL, tool_name: "Bash", arguments: { "command" => "ls -la", "description" => "List files" })
    result = ot_content_markdown(item)

    assert_includes result, "Using tool: Bash"
    assert_includes result, "Parameters:"
    assert_includes result, "command: ls -la"
    assert_includes result, "description: List files"
  end

  test "ot_content_markdown truncates long tool-call string parameters" do
    item = event(Types::TOOL_CALL, tool_name: "Write", arguments: { "content" => "a" * 300 })
    result = ot_content_markdown(item)

    assert_includes result, "Using tool: Write"
    assert_includes result, "..."
    assert result.length < 300
  end

  test "ot_content_markdown renders tool result output parts" do
    item = event(Types::TOOL_RESULT, output: [ OpenTranscript.text_part("done") ], is_error: false)
    assert_equal "done", ot_content_markdown(item)
  end

  test "ot_content_markdown renders a subagent spawn" do
    item = event(Types::SUBAGENT_SPAWN, subagent_type: "Explore", description: "look around", prompt: "go")
    result = ot_content_markdown(item)

    assert_includes result, "**Subagent:** Explore"
    assert_includes result, "look around"
    assert_includes result, "go"
  end

  test "ot_content_markdown renders a compaction with token counts" do
    item = event(Types::COMPACTION, summary: "compacted", trigger: "auto", tokens_before: 1000, tokens_after: 200)
    result = ot_content_markdown(item)

    assert_includes result, "**Context compaction** (auto)"
    assert_includes result, "1000 → 200"
    assert_includes result, "compacted"
  end

  test "ot_content_markdown renders an error message" do
    assert_equal "API Error: boom", ot_content_markdown(event(Types::ERROR, message: "API Error: boom"))
  end

  test "ot_content_markdown renders a system event payload content" do
    item = event(Types::SYSTEM_EVENT, subtype: "system", payload: { "content" => "Tip: use /help" })
    assert_equal "Tip: use /help", ot_content_markdown(item)
  end

  # ---------------------------------------------------------------------------
  # timeline_item_dom_id
  # ---------------------------------------------------------------------------
  # The id is what the reopen backfill (lib/live_region_backfill.js) uses to tell
  # a row it already has from one that arrived while the socket was dead. It is
  # derived rather than stored, so the two render paths agreeing is a property
  # that has to be asserted, not assumed.

  def normalizable_entry
    {
      "type" => "assistant",
      "uuid" => "entry-uuid-1",
      "timestamp" => "2026-08-17T03:00:00.000Z",
      "message" => { "role" => "assistant", "content" => [ { "type" => "text", "text" => "hello world" } ] }
    }
  end

  def session_for_normalizer
    Session.create!(
      prompt: "p",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
  end

  test "timeline_item_dom_id is the same whether the row was broadcast or page-rendered" do
    session = session_for_normalizer
    normalizer = TranscriptRuntime.normalizer_for(session)

    # BroadcastService normalizes without a transcript_index; the controller's
    # page render always supplies one. Including it in the id would give every
    # live-streamed row a different id from its own re-render, and the backfill
    # would append a second copy of everything received since page load.
    broadcast = normalizer.normalize(normalizable_entry, session: session)
    rendered = normalizer.normalize(normalizable_entry, session: session, transcript_index: 7)

    assert_equal broadcast.count, rendered.count
    assert_predicate broadcast, :any?, "the fixture entry normalized into no events"

    broadcast.zip(rendered).each do |live, page|
      assert_equal timeline_item_dom_id(live), timeline_item_dom_id(page),
        "a #{live[:type]} row gets a different id depending on which path rendered it"
    end
  end

  test "timeline_item_dom_id separates the several events one transcript line fans out into" do
    session = session_for_normalizer
    entry = {
      "type" => "assistant",
      "uuid" => "entry-uuid-2",
      "timestamp" => "2026-08-17T03:00:00.000Z",
      "message" => {
        "role" => "assistant",
        "content" => [
          { "type" => "text", "text" => "running a tool" },
          { "type" => "tool_use", "id" => "tool-1", "name" => "Bash", "input" => { "command" => "ls" } }
        ]
      }
    }

    events = TranscriptRuntime.normalizer_for(session).normalize(entry, session: session)
    assert_operator events.count, :>, 1, "the fixture did not fan out into several events"

    ids = events.map { |event| timeline_item_dom_id(event) }
    assert_equal ids.uniq.count, ids.count, "two events from one line collapsed onto the same id"
  end

  test "timeline_item_dom_id distinguishes logs by content and time" do
    at = Time.utc(2026, 8, 17, 3, 0, 0)
    one = { type: "log", level: "info", content: "first", sort_time: at }
    two = { type: "log", level: "info", content: "second", sort_time: at }
    later = { type: "log", level: "info", content: "first", sort_time: at + 1 }

    assert_equal timeline_item_dom_id(one), timeline_item_dom_id(one.dup)
    refute_equal timeline_item_dom_id(one), timeline_item_dom_id(two)
    refute_equal timeline_item_dom_id(one), timeline_item_dom_id(later)
  end

  # The PR button's label does not name the PR's state, so the icon has to. Color
  # alone would leave a reader who cannot distinguish green from red with nothing,
  # which is why the glyph varies too -- these are Primer's git-pull-request,
  # git-merge and git-pull-request-closed octicons.
  test "pr_icon_path gives open, merged and closed distinct glyphs" do
    paths = [ "open", "merged", "closed" ].map { |status| pr_icon_path(status) }

    assert_equal paths.uniq.count, paths.count, "two PR states share an icon glyph"
    paths.each { |path| assert_match(/\A[Mm][\d.]/, path, "not an SVG path: #{path.truncate(40)}") }
  end

  test "pr_icon_path falls back to the open glyph for an unknown status" do
    assert_equal pr_icon_path("open"), pr_icon_path(nil)
    assert_equal pr_icon_path("open"), pr_icon_path("draft")
  end

  test "pr_icon_color_class pairs a distinct color with each PR state" do
    colors = [ "open", "merged", "closed", nil ].map { |status| pr_icon_color_class(status) }

    assert_equal colors.uniq.count, colors.count, "two PR states share an icon color"
  end
end
