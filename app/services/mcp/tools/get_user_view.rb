# frozen_string_literal: true

module Mcp
  module Tools
    # The dashboard's User view, as an agent reads it.
    #
    # Mirrors SessionsController#index in `view=user`: the same filters, the same
    # ordering rule (Sessions::UserView), and the same per-row facts the human sees
    # — title, status, agent root, the generated status blurb, and the PR with its
    # lifecycle state and CI colour.
    #
    # It exists because the Reprioritize button spawns a session whose job is to
    # rewrite that board's order, and scraping the HTML is not a contract. Pair it
    # with `reorder_user_view`, which is the write half.
    #
    # `quick_search_sessions` is NOT this tool. It answers "which sessions exist
    # and how are they scheduled"; three of the four facts a decision on this board
    # turns on — the root, the blurb and the PR — are not on its rows at all, and
    # getting them meant a `get_session` per row.
    class GetUserView < Tool
      # Enough of the blurb to tell what a session is waiting on, short enough
      # that a full page of rows fits in one tool result. Overridable per call.
      DEFAULT_SUMMARY_CHARS = 280
      MAX_SUMMARY_CHARS = 1000

      # Titles are free text and occasionally enormous.
      MAX_TITLE_CHARS = 140

      DEFAULT_PER_PAGE = 50
      MAX_PER_PAGE = 200

      # The same cap the view renders under, so a caller that pages to the end has
      # seen exactly the board.
      MAX_ROWS = SessionsController::USER_VIEW_LIMIT

      # `board` is the order the User view is drawn in (Sessions::UserView).
      # `last_touched` is the dashboard's "Sort By Last Touched" flat view —
      # Session::LAST_TOUCHED_ORDER, the same SQL the web and
      # `GET /api/v1/sessions?view=last_touched` use, with the API's `id desc`
      # tie-break.
      ORDER_BOARD = "board"
      ORDER_LAST_TOUCHED = SessionsController::VIEW_MODE_LAST_TOUCHED
      ORDERS = [ ORDER_BOARD, ORDER_LAST_TOUCHED ].freeze

      tool_name "get_user_view"

      description <<~DESC
        Read the Zimmer dashboard's **User view** — the human's decision board — in the order it is drawn.

        This is the one screen the user works top to bottom, taking a decision on each row without opening the session: Trash it, Snooze it, or Merge its PR. Every fact a row carries is here.

        **The order is the board's order, and it is not just precedence:**
        1. `priority` sessions above `spot` ones (a priority session starts whenever it is ready; a spot session waits for quota room, in precedence order).
        2. Within each class, precedence descending — an absolute scale, so 100000 comes before 50.
        3. Within each, oldest first.

        **Or most recently touched first:** pass `order: "last_touched"` for the dashboard's "Sort By Last Touched" view — the session a person last opened, messaged or acted on comes first, and a session nobody has touched counts from when it was created. Same filters, same rows, one flat list. Every row says when it was last touched either way.

        **For Live Mode, and above all from CarPlay,** the view to reach for when the person asks for their board, or what needs them, is `order: "last_touched"` with `carplay_fit: "not_laptop_only"`: what they were last on, minus what needs a screen.

        **Per row:** title, status, when it was last touched, scheduling class, precedence, agent root, board visibility, CarPlay fit (whether what the row needs from the human can be done by voice from a car — `carplay_ok`, `laptop_only` or untagged, with who judged it and whether that judgement is still current), the generated status summary (Zimmer's own cached "where this stands" blurb, with how many messages have landed since it was written), and the session's most recent pull request with its state (`open`/`merged`/`closed`) and CI verdict (`pass`/`fail`/`pending`). A row marked **Mergeable: yes** is one whose Merge button the user is being offered right now — open, and CI green; one marked **Merge already authorized** is one they have already pressed it on.

        **There is no tool for pressing that button, deliberately.** The Merge button is the one sanctioned route to an agent merging its own work, and it is sanctioned precisely because a human clicked it. What proves a human did is the `HumanMessage` the browser writes for the click — not the `[HUMAN-AUTHORIZED MERGE]` text in the message, which any caller can type. Rank the row; do not try to action it, and never send that marker yourself.

        **Filters default to the board's own defaults**: status `needs_input`, on-board only. That is the population the view exists for — sessions parked waiting on a human. Widen deliberately.

        **Triaging for a driver:** pass `carplay_fit: "not_laptop_only"` to drop the rows that need a screen or a keyboard; the result says how many it dropped, so say that number rather than reading them out. A row that comes back `untagged` is one nobody has judged — read its summary and mark it with `action_session` → `set_carplay_fit`. A session the driver started, followed up or acted on from CarPlay is marked `carplay_ok` with source `carplay` automatically and stays in this view, without going stale, until a later judgement clearly finds a laptop-only step.

        **Write the order back with `reorder_user_view`** — from the board order, not from `last_touched`, which is a different list. Do not try to reorder with `action_session`/`change_precedence` one session at a time: that is one call per row, and it cannot express "this is the order" — a rank you compute from a board that moved under you lands in the wrong place.

        **At scale:** page through with `page`/`per_page` (up to #{MAX_PER_PAGE}), and lower `summary_chars` if the rows are costing more context than the decision needs. The board is capped at #{MAX_ROWS} rows, the same cap the view renders under.
      DESC

      input_schema({
        type: "object",
        properties: {
          status: {
            oneOf: [
              { type: "string", enum: SessionsController::STATUS_FILTER_OPTIONS },
              { type: "array", items: { type: "string", enum: SessionsController::STATUS_FILTER_OPTIONS } }
            ],
            description: 'Statuses to include, one or several. Defaults to ["needs_input"], which is what the board opens on — the sessions actually waiting on a human. Pass an empty array for every status.'
          },
          priority_class: {
            type: "string",
            enum: SessionGenesis::CLASSES,
            description: "Narrow to one scheduling class. Omit for both, which is how the view is drawn."
          },
          agent_root: {
            type: "string",
            description: "Narrow to one agent root, by its catalog name."
          },
          visibility: {
            type: "string",
            enum: SessionVisibility::FILTER_OPTIONS,
            description: '"on_board" (default) hides the rows the user has snoozed or hidden — that is the board as drawn. "off_board" is only those; "all" is both.'
          },
          order: {
            type: "string",
            enum: ORDERS,
            description: '"board" (default) is the User view as drawn: priority above spot, precedence descending, oldest first. "last_touched" is the dashboard\'s Sort By Last Touched view: the session a person last opened, messaged or acted on first, falling back to when it was created. With carplay_fit "not_laptop_only" it is the Live Mode default.'
          },
          carplay_fit: {
            type: "string",
            enum: SessionCarplayFit::FILTER_OPTIONS,
            description: 'Narrow by CARPLAY FIT — whether what a row needs from the human can be done by voice from a car. Omit for the board as drawn. "not_laptop_only" is the driving default: rows marked carplay_ok plus rows nobody has judged yet. "carplay_ok", "laptop_only" and "untagged" are the single buckets; a mark gone stale because the session moved counts as untagged, except a `carplay` mark (the session was engaged from CarPlay), which holds until demoted. The order is unchanged — this only decides which rows are listed.'
          },
          summary_chars: {
            type: "number",
            minimum: 0,
            maximum: MAX_SUMMARY_CHARS,
            description: "How much of each generated status summary to include. Default #{DEFAULT_SUMMARY_CHARS}; 0 omits the blurb entirely, which roughly halves a row when you are ranking a large board."
          },
          page: { type: "number", minimum: 1, description: "Page number. Default: 1" },
          per_page: {
            type: "number",
            minimum: 1,
            maximum: MAX_PER_PAGE,
            description: "Rows per page (1-#{MAX_PER_PAGE}). Default: #{DEFAULT_PER_PAGE}."
          }
        },
        required: []
      })

      def call(args)
        # One more than the cap, so "capped" is only claimed when a row was actually
        # cut off rather than whenever exactly MAX_ROWS sessions match.
        order = requested_order(args)
        fetched = ordered_rows(filtered_scope(args), order, limit: MAX_ROWS + 1)
        capped = fetched.size > MAX_ROWS
        rows = fetched.first(MAX_ROWS)

        page, per_page = pagination(args)
        total_pages = [ (rows.size.to_f / per_page).ceil, 1 ].max
        window = rows[(page - 1) * per_page, per_page] || []

        return "No sessions match these filters — the board is empty." if rows.empty?

        summary_chars = summary_chars(args)
        overrides = AppSetting.current.genesis_class_overrides || {}

        lines = [
          "## User view (the dashboard's decision board)",
          "",
          "#{rows.size} row(s)#{capped ? " — capped at #{MAX_ROWS}, narrow the filters to see the rest" : ''}, page #{page} of #{total_pages}.",
          order_line(order),
          carplay_hidden_line(args),
          ""
        ].compact

        window.each_with_index do |session, index|
          lines << format_row(session, position: (page - 1) * per_page + index + 1,
                                       summary_chars: summary_chars, overrides: overrides)
          lines << ""
        end

        if page < total_pages
          lines << "---"
          lines << "*More rows. Use page=#{page + 1}.*"
        else
          lines << "---"
          lines << if order == ORDER_LAST_TOUCHED
            "*That is every matching row. This is not the board's order: to write one back with `reorder_user_view`, read the board with the default order first.*"
          else
            "*That is the whole board. Write an order back with `reorder_user_view`, top to bottom.*"
          end
        end

        lines.join("\n")
      end

      private

      def requested_order(args)
        ORDERS.include?(args["order"].to_s) ? args["order"].to_s : ORDER_BOARD
      end

      def ordered_rows(scope, order, limit:)
        return Sessions::UserView.rows(scope: scope, limit: limit) unless order == ORDER_LAST_TOUCHED

        # id desc breaks ties the way GET /api/v1/sessions?view=last_touched does.
        scope.reorder(Session::LAST_TOUCHED_ORDER).order(id: :desc).limit(limit).to_a
      end

      # So a driver can be told what was left for the laptop without the rows
      # being read out. Counted against every other filter, uncapped.
      def carplay_hidden_line(args)
        return nil if args["carplay_fit"].blank?

        hidden = filtered_scope(args.except("carplay_fit")).count(:all) - filtered_scope(args).count(:all)
        "The carplay_fit filter (#{args['carplay_fit']}) left out #{hidden} row(s) that match the other filters."
      end

      def order_line(order)
        if order == ORDER_LAST_TOUCHED
          "Ordered by last touched, most recent first — the dashboard's Sort By Last Touched view, not the board's order."
        else
          "Ordered top to bottom exactly as the human sees it: priority above spot, then precedence descending."
        end
      end

      def filtered_scope(args)
        # `transcript` is a legacy JSON column still on `sessions`, and this reads up
        # to MAX_ROWS rows before it pages — the same reason the web view drops it.
        scope = Session.excluding_status_summary_forks
          .select(Session.column_names - [ "transcript" ])
          .includes(:status_summary)

        statuses = requested_statuses(args)
        scope = scope.where(status: statuses) if statuses.any?

        scope = scope.priority_classified(args["priority_class"]) if args["priority_class"].present?

        if args["agent_root"].present?
          scope = scope.where("sessions.metadata->>'agent_root_key' = ?", args["agent_root"].to_s)
        end

        scope = case args["visibility"].presence || SessionVisibility::FILTER_ON_BOARD
        when SessionVisibility::FILTER_OFF_BOARD then scope.board_hidden
        when SessionVisibility::FILTER_ALL then scope
        else scope.board_visible
        end

        # The driver's axis. Only narrows when asked, and never reorders: a
        # laptop-only row keeps its place for the laptop.
        scope = scope.carplay_fit_filter(args["carplay_fit"]) if args["carplay_fit"].present?
        scope
      end

      # An ABSENT status filter defaults to the board's own default; an explicitly
      # empty array means "every status". Those are different requests and the
      # difference is `key?`, exactly as the dashboard's own Filters form treats it.
      def requested_statuses(args)
        return SessionsController::DEFAULT_STATUS_FILTER unless args.key?("status")

        Array(args["status"]).map(&:to_s) & SessionsController::STATUS_FILTER_OPTIONS
      end

      def pagination(args)
        page = [ args["page"].to_i, 1 ].max
        per_page = args["per_page"].to_i
        per_page = DEFAULT_PER_PAGE if per_page <= 0
        [ page, per_page.clamp(1, MAX_PER_PAGE) ]
      end

      def summary_chars(args)
        return DEFAULT_SUMMARY_CHARS unless args.key?("summary_chars")

        args["summary_chars"].to_i.clamp(0, MAX_SUMMARY_CHARS)
      end

      def format_row(session, position:, summary_chars:, overrides:)
        pr = Sessions::PrSummary.for(session)

        lines = [
          "### #{position}. #{truncate(session.title.presence || 'Untitled session', MAX_TITLE_CHARS)} (ID: #{session.id})",
          "",
          "- **Status:** #{session.status}",
          "- **Last touched:** #{last_touched(session)}",
          "- **Class:** #{session.priority_class(overrides)} (genesis: #{session.genesis_key}), precedence #{session.precedence}",
          "- **Agent root:** #{session.agent_root_key.presence || '(none)'}"
        ]

        if (tucked = session.visibility_summary)
          lines << "- **Visibility:** #{tucked} — presentation only; it does not affect scheduling."
        end

        lines << "- **CarPlay fit:** #{session.carplay_fit_summary || 'untagged'}"

        if pr.any?
          detail = [ "state #{pr.status || 'unknown'}" ]
          detail << "CI #{pr.ci_status}" if pr.ci_status.present?
          detail << "#{pr.count} PRs on this session, newest shown" if pr.count > 1
          lines << "- **PR:** #{pr.url} (#{detail.join(', ')})"
          lines << "- **Mergeable:** #{pr.mergeable? ? 'yes — the user is being offered a Merge button for this row' : "no — #{pr.merge_blocked_reason}"}"

          # Reported because a row the human has ALREADY actioned is not a row
          # they need near the top of the board. Without it, a reprioritizing
          # session would keep ranking an authorized merge as an outstanding
          # decision every time the button is pressed.
          if (authorized = Sessions::AuthorizeMerge.authorized_at(session, pr.url))
            lines << "- **Merge already authorized** at #{authorized} — the human has pressed Merge on this " \
                     "row and the session has been told to merge. Nothing is waiting on them here."
          end
        else
          lines << "- **PR:** none recorded"
        end

        if summary_chars.positive?
          summary = session.status_summary
          if summary&.summary.present?
            behind = summary.messages_since(session.transcript_line_count)
            freshness = behind.zero? ? "current" : "#{behind} message(s) since it was written"
            lines << "- **Generated status** (#{freshness}): #{truncate(summary.summary, summary_chars)}"
          else
            lines << "- **Generated status:** none yet"
          end
        end

        lines.join("\n")
      end

      # The ISO time keeps the order checkable; the relative part is what a voice
      # reply says out loud.
      def last_touched(session)
        at = session.last_user_activity_at

        # The accessor falls back to created_at when nothing usable was recorded.
        touched = at == session.created_at ? " (never touched — this is when it was created)" : ""
        "#{at.utc.iso8601} (#{ActionController::Base.helpers.time_ago_in_words(at)} ago)#{touched}"
      end

      def truncate(text, limit)
        # Newlines would break the one-line-per-fact shape of the row.
        flat = text.to_s.gsub(/\s+/, " ").strip
        flat.length <= limit ? flat : "#{flat[0, limit]}…"
      end
    end
  end
end
