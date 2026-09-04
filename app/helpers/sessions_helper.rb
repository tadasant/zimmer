module SessionsHelper
  # The per-genesis class overrides, read once per render.
  #
  # Every session card asks "am I spot or priority", and unless a class was named
  # for that session the answer is derived rather than stored, so that promoting a
  # genesis reclassifies existing sessions. Derived means a lookup, and a page of
  # 50 cards would otherwise make 50
  # identical AppSetting reads. Memoized on the view instance, which lives exactly
  # one request — long enough to save the queries, short enough that a promotion
  # made in another tab is reflected on the next page load.
  def cached_genesis_overrides
    @cached_genesis_overrides ||= AppSetting.current.genesis_class_overrides || {}
  end

  # Extracts the actionable error line(s) from a failed session's exception
  # message so the failure UI can surface them prominently above the raw output.
  # Returns nil when the message doesn't mix warnings and errors (nothing to
  # disambiguate) — see ExceptionMessageHighlighter.
  def failure_error_highlights(exception_message)
    ExceptionMessageHighlighter.highlights(exception_message)
  end

  # When the account pool that parked this session is expected to roll over, as
  # AuthOutageParkService estimated it at park time. An estimate for the banner —
  # nothing fires at it. Returns nil when the session isn't parked, when no reset
  # time was knowable, or when the stored value isn't a parseable timestamp, so
  # the banner falls back rather than raising on metadata written by an older
  # release.
  def auth_outage_pool_recovery_time(agent_session)
    AuthOutageParkService.pool_recovery_time(agent_session)
  end

  # Resolve a goal value to its display name using predefined goals.
  # Returns the matching goal name, "Custom" if set but unrecognized, or nil if blank.
  def goal_display_name(goal, goals_for_select)
    return nil if goal.blank?

    matching = (goals_for_select || []).find { |g| g[:description] == goal || g[:id] == goal }
    matching ? matching[:name] : "Custom"
  end

  # Returns the CSS class for PR icon color based on status
  def pr_icon_color_class(status)
    case status
    when "merged" then "text-purple-600"
    when "open" then "text-green-600"
    when "closed" then "text-red-600"
    else "text-gray-400"
    end
  end

  # The 16px Primer octicon path for a PR's state: `git-pull-request`,
  # `git-merge`, `git-pull-request-closed`. Paired with #pr_icon_color_class so
  # that state is carried by the glyph's shape as well as its color -- the PR
  # button's label does not name the state, and color on its own is not a channel
  # every reader has (WCAG 1.4.1).
  def pr_icon_path(status)
    case status
    when "merged"
      "M5.45 5.154A4.25 4.25 0 0 0 9.25 7.5h1.378a2.251 2.251 0 1 1 0 1.5H9.25A5.734 5.734 0 0 1 5 7.123v3.505a2.25 2.25 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.95-.218ZM4.25 13.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm8.5-4.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5ZM5 3.25a.75.75 0 1 0 0 .005V3.25Z"
    when "closed"
      "M3.25 1A2.25 2.25 0 0 1 4 5.372v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.251 2.251 0 0 1 3.25 1Zm9.5 5.5a.75.75 0 0 1 .75.75v3.378a2.251 2.251 0 1 1-1.5 0V7.25a.75.75 0 0 1 .75-.75Zm-2.03-5.273a.75.75 0 0 1 1.06 0l.97.97.97-.97a.748.748 0 0 1 1.265.332.75.75 0 0 1-.205.729l-.97.97.97.97a.751.751 0 0 1-.018 1.042.751.751 0 0 1-1.042.018l-.97-.97-.97.97a.749.749 0 0 1-1.275-.326.749.749 0 0 1 .215-.734l.97-.97-.97-.97a.75.75 0 0 1 0-1.06ZM2.5 3.25a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0ZM3.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm9.5 0a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z"
    else
      "M1.5 3.25a2.25 2.25 0 1 1 3 2.122v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.25 2.25 0 0 1 1.5 3.25Zm5.677-.177L9.573.677A.25.25 0 0 1 10 .854V2.5h1A2.5 2.5 0 0 1 13.5 5v5.628a2.251 2.251 0 1 1-1.5 0V5a1 1 0 0 0-1-1h-1v1.646a.25.25 0 0 1-.427.177L7.177 3.427a.25.25 0 0 1 0-.354ZM3.75 2.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm0 9.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm8.25.75a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Z"
    end
  end

  # Returns the CSS class for CI status indicator color
  # CI statuses: pass (green), fail (red), pending (yellow), cancel (gray), skipping (gray)
  def ci_status_color_class(ci_status)
    case ci_status
    when "pass" then "text-green-500"
    when "fail" then "text-red-500"
    when "pending" then "text-yellow-500"
    when "cancel", "skipping" then "text-gray-400"
    else "text-gray-300"
    end
  end

  # Returns the background CSS class for CI status indicator
  def ci_status_bg_class(ci_status)
    case ci_status
    when "pass" then "bg-green-500"
    when "fail" then "bg-red-500"
    when "pending" then "bg-yellow-500"
    when "cancel", "skipping" then "bg-gray-400"
    else "bg-gray-300"
    end
  end

  # Extract PR number from a GitHub PR URL for display
  def extract_pr_number(url)
    match = url.to_s.match(%r{/pull/(\d+)})
    match ? "##{match[1]}" : "PR"
  end

  # Returns the CSS classes for session status badges. This is the one session
  # status -> colour map in the app: the session partials and /health both read it,
  # so a status means the same colour wherever a human sees it.
  #
  # Takes the status string rather than a session, because /health counts statuses
  # (`Session.group(:status).count`) and never has a record to hand.
  #
  # Running badges start green and update dynamically via JS based on elapsed time
  # Other statuses have fixed colors that don't clash with running's green/yellow/red
  def status_badge_classes(status)
    case status.to_s
    when "running"
      # Default to green, JS will update based on elapsed time
      "bg-green-100 text-green-800"
    when "waiting"
      # Purple for waiting, so it cannot be read as running's yellow
      "bg-purple-100 text-purple-800"
    when "needs_input"
      # Blue for needs input
      "bg-blue-100 text-blue-800"
    when "failed"
      # Orange for failed (distinct from running's red which indicates long duration)
      "bg-orange-100 text-orange-800"
    else
      # Gray for archived and any other status
      "bg-gray-100 text-gray-800"
    end
  end

  # The session-card grid, shared by every board that renders cards: the category
  # sections, the pinned strip, the flat lists and the search results. One method
  # rather than the same string five times, because the string carries a rule that
  # is easy to get wrong and impossible to notice going wrong on a laptop.
  #
  # The rule is the track's floor. A bare `minmax(320px, 400px)` reads as "between
  # 320 and 400", but a grid track can never resolve below its own floor — so in a
  # container narrower than 320px the single track is laid out at 320px anyway, and
  # `justify-center` centres that too-wide track by hanging it off both edges. The
  # dashboard's `px-4` gutter leaves 288px of grid at a 320px viewport, which is
  # exactly that case: the card sits outside the content column the rest of the page
  # keeps, and below 320px the page scrolls sideways outright (#803).
  #
  # Wrapping the floor in `min(320px, 100%)` is the conventional idiom for it: it is
  # 320px whenever 320px fits and the container's own width when it does not, so the
  # track is never wider than the thing it sits in. A container of 320px or more is
  # unaffected, since `min()` picks the 320px there.
  def session_card_grid_classes
    "grid gap-6 grid-cols-[repeat(auto-fill,minmax(min(320px,100%),400px))] justify-center"
  end

  # ---------------------------------------------------------------------------
  # OpenTranscripts display helpers
  # ---------------------------------------------------------------------------
  # These render a single OpenTranscripts event (see OpenTranscript) for the
  # unified timeline_items/_item partial. They key on the event :type rather
  # than decoding per-runtime content blocks, so both runtimes render through
  # one path.

  # A stable DOM id for one timeline row.
  #
  # Timeline items are not records — a row is a Log, an MCP log, or one of the
  # several OpenTranscripts events a single transcript line fans out into — so
  # there is no primary key to name them by. The id is therefore derived from
  # what the row *is*. That supports the one thing it has to: telling whether a
  # row the server just rendered is already on screen — the reopen backfill in
  # lib/live_region_backfill.js appends by id, and a row it cannot identify is a
  # row it would either duplicate or drop.
  #
  # The same partial renders the broadcast append and the full-page render, and
  # the two have to agree. That is what dictates the inputs, and it rules out
  # `transcript_index` in particular: BroadcastService normalizes without one (it
  # applies to page-load rendering and fork-from-here, not to a live event), so
  # including it gives every live-streamed row a different id from its own
  # re-render — and the backfill then appends a second copy of everything that
  # arrived over the socket. `id` and `event_order` come off the normalizer
  # identically on both paths and already separate the several events one
  # transcript line fans out into. Logs carry neither, and are keyed by their
  # level, content and time.
  #
  # test/helpers/sessions_helper_test.rb is the guard: it normalizes one entry
  # both ways and asserts the ids match.
  #
  # Two rows genuinely identical in every input collide, and are then treated as
  # one. They are also indistinguishable to a reader, so that is the right answer
  # rather than a compromise.
  def timeline_item_dom_id(item)
    fingerprint = [
      item[:type],
      item[:id],
      item[:event_order],
      item[:sort_time].try(:iso8601, 6) || item[:sort_time],
      item[:level],
      item[:content]
    ].map(&:to_s).join(" ")

    "timeline-item-#{Digest::SHA256.hexdigest(fingerprint).first(20)}"
  end

  # Human-readable label for an event's header.
  def ot_event_label(item)
    case item[:type]
    when OpenTranscript::Types::USER_MESSAGE then "User"
    when OpenTranscript::Types::ASSISTANT_MESSAGE then "Assistant"
    when OpenTranscript::Types::THINKING then "Thinking"
    when OpenTranscript::Types::TOOL_CALL then "Tool: #{item[:tool_name].presence || 'unknown'}"
    when OpenTranscript::Types::TOOL_RESULT then item[:is_error] ? "Tool Result (Error)" : "Tool Result"
    when OpenTranscript::Types::SUBAGENT_SPAWN then "Subagent"
    when OpenTranscript::Types::COMPACTION then "Compaction"
    when OpenTranscript::Types::ERROR then "Error"
    when OpenTranscript::Types::SYSTEM_EVENT
      case item[:subtype]
      when "queue-operation" then "Queue Event"
      when OpenTranscript::SystemEventSubtypes::RUNTIME_NOTICE then "Runtime Notice"
      else (item[:subtype].presence || "system").to_s.titleize
      end
    else "Event"
    end
  end

  # Which icon glyph to draw (see timeline_items/_item.html.erb).
  def ot_icon_kind(item)
    case item[:type]
    when OpenTranscript::Types::USER_MESSAGE then :user
    when OpenTranscript::Types::ASSISTANT_MESSAGE then :assistant
    when OpenTranscript::Types::THINKING then :thinking
    when OpenTranscript::Types::TOOL_CALL, OpenTranscript::Types::TOOL_RESULT, OpenTranscript::Types::SUBAGENT_SPAWN then :tool
    when OpenTranscript::Types::ERROR then :error
    else :system
    end
  end

  def ot_badge_class(item)
    case ot_icon_kind(item)
    when :user then "bg-indigo-100"
    when :assistant then "bg-green-100"
    when :thinking then "bg-yellow-100"
    when :tool then "bg-purple-100"
    when :error then "bg-red-100"
    else "bg-cyan-100"
    end
  end

  def ot_icon_color(item)
    case ot_icon_kind(item)
    when :user then "text-indigo-600"
    when :assistant then "text-green-600"
    when :thinking then "text-yellow-600"
    when :tool then "text-purple-600"
    when :error then "text-red-600"
    else "text-cyan-600"
    end
  end

  # True for a line the coding agent's CLI wrote into its own transcript wearing
  # a user role (see ClaudeTranscriptNormalizer::RUNTIME_NOTICE_FLAGS). Used to
  # keep the row out of the affordances that only make sense on a real message.
  def ot_runtime_notice?(item)
    item[:type] == OpenTranscript::Types::SYSTEM_EVENT &&
      item[:subtype] == OpenTranscript::SystemEventSubtypes::RUNTIME_NOTICE
  end

  # Runtime notices long enough to bury the conversation they sit in are drawn
  # collapsed: a one-line digest in the row, the full text behind a disclosure.
  # The case that motivated it is the `isMeta` line Claude Code writes when a
  # skill fires — an entire SKILL.md, verbatim, in the transcript. Across a
  # production host's transcripts the smallest of those is 3.4k characters and
  # the largest 690k, and two or three of them are enough to push the actual
  # conversation off the page.
  #
  # Returns { label:, token_summary: } for a notice that should render
  # collapsed, or nil for one that should print in full as before. Two triggers:
  #
  #   * the skill-dump shape — a first line reading "Base directory for this
  #     skill: <path>", which the CLI writes ahead of the injected body. It
  #     names the skill, and it is what gives the digest a real label.
  #   * any other notice longer than RUNTIME_NOTICE_COLLAPSE_CHARS. The notices
  #     that are not skill dumps are overwhelmingly one-liners — "Continue from
  #     where you left off." is 33 characters, the malformed-tool-call nudges
  #     under 100 — so the threshold sits far above them on purpose.
  #
  # Both triggers are floored at RUNTIME_NOTICE_FLOOR_CHARS, because folding a
  # short notice away behind an accordion is worse than leaving it alone and
  # that is true of a short skill dump too. No skill on this host is anywhere
  # near the floor — the smallest is 3.4k characters — so the floor never fires
  # today; it is there so a genuinely tiny SKILL.md cannot make a one-line row
  # into an accordion.
  #
  # Presentation only: nothing is removed from the transcript. The full text
  # still renders when expanded, is still what the copy button copies, and the
  # plain-text export (TranscriptTextRenderer) never comes through here.
  def ot_runtime_notice_digest(item)
    return nil unless ot_runtime_notice?(item)

    payload = item[:payload]
    text = payload.is_a?(Hash) ? payload["text"].to_s : ""
    return nil if text.length <= RUNTIME_NOTICE_FLOOR_CHARS

    skill = ot_runtime_notice_skill_name(text)
    return nil if skill.nil? && text.length <= RUNTIME_NOTICE_COLLAPSE_CHARS

    {
      label: skill || ot_runtime_notice_fallback_label(text),
      token_summary: ot_approx_token_summary(text)
    }
  end

  # Text longer than this, with no skill name to go on, still collapses. Set
  # well clear of the short scaffolding lines the same flag carries.
  RUNTIME_NOTICE_COLLAPSE_CHARS = 2_000

  # Nothing shorter than this collapses, whatever shape it is. Roughly a screen
  # of prose — below it there is nothing to hide.
  RUNTIME_NOTICE_FLOOR_CHARS = 400

  # Whether this event row should get the subtle gray tool background.
  def ot_tool_row?(item)
    %w[Thinking ToolCall ToolResult SubagentSpawn].include?(item[:type])
  end

  # Count of image ContentParts in a message event (for the image badge).
  def ot_image_count(item)
    parts = item[:content]
    return 0 unless parts.is_a?(Array)

    parts.count { |p| p.is_a?(Hash) && p["type"] == "image" }
  end

  # The markdown body rendered for an event via shared/enhanced_markdown.
  def ot_content_markdown(item)
    case item[:type]
    when OpenTranscript::Types::USER_MESSAGE, OpenTranscript::Types::ASSISTANT_MESSAGE
      ot_parts_to_markdown(item[:content])
    when OpenTranscript::Types::TOOL_RESULT
      ot_parts_to_markdown(item[:output])
    when OpenTranscript::Types::THINKING
      item[:text].to_s
    when OpenTranscript::Types::TOOL_CALL
      ot_tool_call_markdown(item)
    when OpenTranscript::Types::SUBAGENT_SPAWN
      ot_subagent_spawn_markdown(item)
    when OpenTranscript::Types::COMPACTION
      ot_compaction_markdown(item)
    when OpenTranscript::Types::ERROR
      item[:message].to_s
    when OpenTranscript::Types::SYSTEM_EVENT
      ot_runtime_notice?(item) ? ot_runtime_notice_markdown(item) : ot_system_event_markdown(item)
    else
      ""
    end
  end

  private

  # Join a ContentPart[] into a markdown string. Text parts pass through; image
  # parts render a visual placeholder (image data is not inlined).
  def ot_parts_to_markdown(parts)
    return "" unless parts.is_a?(Array)

    parts.filter_map do |part|
      next unless part.is_a?(Hash)

      case part["type"]
      when "text"
        part["text"]
      when "image"
        type_label = part["mime_type"].to_s.split("/").last.presence&.upcase || "IMAGE"
        "[Image attached: #{type_label}]"
      end
    end.join("\n\n")
  end

  def ot_tool_call_markdown(item)
    parts = [ "Using tool: #{item[:tool_name].presence || 'Unknown Tool'}" ]
    arguments = item[:arguments]

    if arguments.is_a?(Hash) && arguments.any?
      parts << "Parameters:"
      arguments.each do |key, value|
        parts << "  #{key}: #{format_parameter_value(value)}"
      end
    end

    parts.join("\n")
  end

  def ot_subagent_spawn_markdown(item)
    parts = []
    parts << "**Subagent:** #{item[:subagent_type]}" if item[:subagent_type].present?
    parts << item[:description] if item[:description].present?
    parts << "" if parts.any? && item[:prompt].present?
    parts << item[:prompt] if item[:prompt].present?
    parts.join("\n")
  end

  def ot_compaction_markdown(item)
    header = "**Context compaction**"
    header += " (#{item[:trigger]})" if item[:trigger].present?

    parts = [ header ]
    if item[:tokens_before].present? || item[:tokens_after].present?
      parts << "Tokens: #{item[:tokens_before] || '?'} → #{item[:tokens_after] || '?'}"
    end
    parts << item[:summary] if item[:summary].present?
    parts.join("\n")
  end

  # A runtime notice renders the text the CLI wrote, under a line saying who
  # wrote it. The wording inside the text is Claude Code's — "[Request
  # interrupted by user for tool use]" says "by user" and is not ours to change
  # — so the attribution Zimmer wraps around it has to carry the correction.
  #
  # The flag names and their explanations ride on the payload rather than being
  # looked up from a runtime's normalizer, so this stays runtime-agnostic like
  # the rest of the OpenTranscripts display helpers.
  def ot_runtime_notice_markdown(item)
    payload = item[:payload]
    payload = {} unless payload.is_a?(Hash)

    markers = payload["markers"]
    reasons = (markers.is_a?(Array) ? markers : []).filter_map do |marker|
      next unless marker.is_a?(Hash) && marker["flag"].present?

      marker["reason"].present? ? "#{marker['reason']} (`#{marker['flag']}`)" : "`#{marker['flag']}`"
    end

    attribution = "*Written by the agent runtime, not typed by a person"
    attribution += ": #{reasons.to_sentence}" if reasons.any?
    attribution += ".*"

    [ attribution, payload["text"].to_s.presence ].compact.join("\n\n")
  end

  # The skill a runtime notice is injecting, from the header line Claude Code
  # writes ahead of the SKILL.md body:
  #
  #   Base directory for this skill: /…/.claude/skills/<skill-name>
  #
  # Anchored at the start of the text so a stray mention further down cannot
  # relabel an unrelated notice, and the basename is required to look like a
  # skill id — a malformed path falls back to the first-line label rather than
  # putting a path fragment in the header. "." and ".." pass that shape test and
  # are excluded by name: they are what File.basename returns for a path that
  # names no file, and either would be a meaningless one-character header.
  SKILL_DUMP_HEADER = /\ABase directory for this skill:[ \t]*(\S.*)$/
  SKILL_ID = /\A[\w.-]+\z/
  NOT_A_SKILL_NAME = %w[. ..].freeze

  def ot_runtime_notice_skill_name(text)
    match = SKILL_DUMP_HEADER.match(text.to_s.lstrip)
    return nil unless match

    name = File.basename(match[1].strip)
    return nil if NOT_A_SKILL_NAME.include?(name)

    name.match?(SKILL_ID) ? name : nil
  end

  # What a large notice is called when it is not a skill dump: its own first
  # line, which for the CLI's longer scaffolding ("The coordinator sent a
  # message while you were working:") already says what the block is. Only a
  # notice with no readable first line gets the generic label.
  def ot_runtime_notice_fallback_label(text)
    first_line = text.to_s.lines.find { |line| line.strip.present? }.to_s.strip
    first_line.present? ? first_line.truncate(80) : "Injected context"
  end

  # A character-count estimate of the tokens the notice cost, worded so nobody
  # reads it as a billing figure. Four characters per token is the usual rough
  # rule for English prose; the real count depends on the tokenizer and Zimmer
  # does not run one at render time.
  APPROX_CHARS_PER_TOKEN = 4

  def ot_approx_token_summary(text)
    tokens = (text.to_s.length / APPROX_CHARS_PER_TOKEN.to_f).round
    rounded = tokens < 1_000 ? tokens.to_s : "#{(tokens / 1_000.0).round(1)}k"

    "approx. #{rounded} tokens"
  end

  def ot_system_event_markdown(item)
    payload = item[:payload]
    return "" unless payload.is_a?(Hash)

    parts = []
    parts << "**Operation:** #{payload['operation'].to_s.titleize}" if payload["operation"].present?
    if payload["content"].is_a?(String) && payload["content"].present?
      parts << payload["content"]
    elsif parts.empty?
      parts << format_hash_preview(payload.except("type"))
    end
    parts.join("\n")
  end

  def format_hash_preview(hash, max_depth: 1)
    return "{}" if hash.empty?
    return "{...}" if max_depth <= 0

    preview_items = hash.first(3).map do |key, value|
      value_preview = case value
      when String
        value.length > 50 ? "\"#{value[0...50]}...\"" : "\"#{value}\""
      when Array
        "[#{value.length} items]"
      when Hash
        format_hash_preview(value, max_depth: max_depth - 1)
      else
        value.to_s
      end
      "#{key}: #{value_preview}"
    end

    suffix = hash.size > 3 ? ", ..." : ""
    "{#{preview_items.join(', ')}#{suffix}}"
  end

  def format_parameter_value(value)
    case value
    when String
      # Truncate long strings
      value.length > 200 ? "#{value[0...200]}..." : value
    when Array
      # Show array info
      "[Array with #{value.length} items]"
    when Hash
      # Show hash info
      "{#{value.keys.join(', ')}}"
    else
      value.to_s
    end
  end
  # Link data for pointing at a session from anywhere the dashboard's right-side
  # drawer might be mounted — a card, a ranked row, a node in the hierarchy tree
  # rendered INSIDE the drawer itself.
  #
  # The href stays the full session page, so middle-click, ⌘/Ctrl-click and the
  # no-JS path all do the obvious thing. session-drawer#open intercepts a plain
  # left-click and loads `session_drawer_url` — a different path — into the
  # drawer's frame.
  #
  # Keeping those two URLs disjoint is what fixes the drawer's intermittent
  # "Content missing": the frame only ever fetches a URL that no <a> on the page
  # points at, so Turbo 8's URL-keyed hover-prefetch cache can never hold an
  # entry for it and can never splice a frameless body into the frame's own
  # fetch. See SessionsController#drawer for the full mechanism.
  #
  # turbo_frame: "_top" matters most for the in-drawer case: without it a link
  # inside <turbo-frame id="session_detail"> would navigate that frame to the
  # full-page URL and land on a body with no matching frame.
  def session_drawer_link_data(session_or_id, **extra)
    { turbo_frame: "_top",
      action: "click->session-drawer#open",
      session_drawer_url: drawer_session_path(session_or_id) }.merge(extra)
  end
end
