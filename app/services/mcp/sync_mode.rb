# frozen_string_literal: true

module Mcp
  # `sync: true` on the tools that send a prompt into a session — `quick_router`,
  # `start_session` and `action_session` → `follow_up`. The prompt is sent
  # exactly as without it; the call then holds until the session has answered
  # that prompt (Sessions::SyncReply) and returns the answer inline, so a caller
  # that would otherwise poll `get_session` makes one call instead.
  #
  # Included into the tool; uses its `session_url` and `context`.
  module SyncMode
    SYNC_DESC = "Optional, default false. When true, this call does not return until the session has " \
                "answered THIS prompt — it comes to rest in needs_input, goes to sleep on a wake-up, " \
                "archives itself, fails, or hands its turn on — and the result carries the session's reply " \
                "text inline, any sessions it started, and its resulting status. Use it when you would " \
                "otherwise poll `get_session` for the answer. The wait is capped at " \
                "#{Sessions::SyncReply::MAX_TIMEOUT_SECONDS}s: if the session is still working then, the " \
                "call returns its id, URL, status and anything it has said so far, and you follow it with " \
                "`get_session` as usual. A session spawned by this one is listed, never waited on. Inside a " \
                "Zimmer session, prefer `wake_me_up_when_session_changes_state`, which holds no server " \
                "thread while you wait."

    SYNC_TIMEOUT_DESC = "Optional, with `sync: true`. How long to wait, in seconds. Default and maximum " \
                        "#{Sessions::SyncReply::MAX_TIMEOUT_SECONDS} — the longest a request survives the " \
                        "proxies in front of Zimmer. A larger value is clamped to it."

    SCHEMA_PROPERTIES = {
      sync: { type: "boolean", description: SYNC_DESC },
      sync_timeout_seconds: { type: "number", description: SYNC_TIMEOUT_DESC }
    }.freeze

    OUTCOME_PHRASES = {
      needs_input: "Answered — the session has come to rest in `needs_input`, waiting for whoever talks to it next.",
      asleep: "Answered — the session has gone to sleep on a wake-up of its own (`waiting`) and will resume itself.",
      moved_on: "Answered — the session finished this turn and has already moved on to its next one " \
                "(a queued message, or a turn Zimmer resumed). The reply below is the turn this prompt started.",
      blocked_on_elicitation: "Paused mid-turn — the session is waiting on an approval request from one of its " \
                              "MCP servers. Answer it with `respond_to_elicitation`; the reply below is what it " \
                              "had said so far.",
      archived: "The session is archived — it finished (or was archived) without waiting for a reply.",
      failed: "The session failed. `get_session` shows why; `action_session` with `restart` retries it.",
      undelivered: "The prompt was not delivered: its queued message was marked undelivered. `get_session` " \
                   "shows the queue."
    }.freeze

    private

    def sync_requested?(args)
      ActiveModel::Type::Boolean.new.cast(args["sync"]) || false
    end

    # Checked before anything is sent, so a bad value never costs a delivery.
    def sync_timeout(args)
      Sessions::SyncReply.timeout_from(args["sync_timeout_seconds"])
    rescue ArgumentError, TypeError
      raise ToolError, "sync_timeout_seconds must be a positive number of seconds " \
                       "(at most #{Sessions::SyncReply::MAX_TIMEOUT_SECONDS})"
    end

    # Wait in a slot, or report the state now when every slot is taken.
    def await_reply(waiter, timeout)
      Sessions::SyncReply.with_slot { waiter.wait(timeout: timeout) } || waiter.over_capacity
    end

    def format_sync_result(result, heading:)
      session = result.session
      lines = [
        "## #{heading}",
        "",
        "- **ID:** #{session.id}",
        "- **URL:** #{session_url(session)}",
        "- **Status:** #{session.status}"
      ]
      lines << "- **Waited:** #{result.elapsed_seconds}s" unless result.outcome == :over_capacity
      lines << "- **Outcome:** #{outcome_phrase(result)}"
      lines.concat(reply_lines(result))
      lines.concat(children_lines(result.children))
      lines.concat(follow_lines(result, session))
      lines.join("\n")
    end

    def outcome_phrase(result)
      case result.outcome
      when :timed_out
        position = result.queued_position ? " Your message is still queued, at position #{result.queued_position}." : ""
        "Still working — this call stopped waiting after #{result.elapsed_seconds}s, and the session carries on." \
          "#{position}"
      when :over_capacity
        "Not waited on — another sync call is already holding this server's wait slot " \
          "(#{Sessions::SyncReply::MAX_CONCURRENT_WAITS} at a time), so this one returned at once. " \
          "The prompt was sent all the same."
      else
        OUTCOME_PHRASES.fetch(result.outcome)
      end
    end

    def reply_lines(result)
      heading = result.finished? ? "### Reply" : "### What it has said so far"
      body = if result.reply.present?
        result.reply_truncated ? "_(The start of a long reply was cut; `get_session` has all of it.)_\n\n#{result.reply}" : result.reply
      else
        "_Nothing yet._"
      end
      [ "", heading, "", body ]
    end

    def children_lines(children)
      return [] if children.empty?

      [ "", "### Sessions it started", "" ] + children.map do |child|
        "- ##{child.id} #{child.title.presence || '(untitled)'} — #{child.status} — #{session_url(child)}"
      end + [ "", "Those sessions carry on on their own; this call did not wait for them. `get_session` on one " \
                  "follows it." ]
    end

    def follow_lines(result, session)
      if result.finished?
        [ "", "Reply to it with `action_session` → `follow_up` (`sync: true` works there too)." ]
      else
        [
          "",
          "To follow it, call `get_session` with id `#{session.id}`: when the status is `needs_input` or " \
          "`archived` it has replied. Pass `transcript_conversation_only: true` and `transcript_tail: 10` " \
          "for its own words."
        ]
      end
    end
  end
end
