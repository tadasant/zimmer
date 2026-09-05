# frozen_string_literal: true

module Mcp
  # The markdown rendering of what is sitting in a session's message queue.
  #
  # `manage_enqueued_messages` renders that queue in full — every status, every
  # message, paginated. `get_session` renders the part a caller needs *before* it
  # decides what to do with a session: how many messages are already pending, and
  # enough of each to recognise it by. The two write paths that add to a queue —
  # `action_session` `follow_up` and `manage_enqueued_messages` `create` — report
  # the depth the caller's own message landed in. One module, so those surfaces
  # cannot drift on what "pending" means or where a preview is cut.
  #
  # Why `get_session` carries it at all: that dump is what a caller reads before
  # deciding whether to send a follow-up, and without this section a queue is
  # invisible to it. Four orchestrator sessions each correctly declined to spawn a
  # duplicate and each appended to the same unread queue, three of them restating
  # the message above it (#698).
  module EnqueuedMessageSections
    # The full-queue preview `manage_enqueued_messages` cuts at, matching the
    # decoupled server's 200-char snippet.
    CONTENT_PREVIEW_LIMIT = 200

    # `get_session`'s own cut, deliberately much tighter. That output already
    # exceeds the MCP tool-result size limit on a large session (#652), so this
    # section is a count plus enough text to tell one queued message from
    # another — never the message. `manage_enqueued_messages` is one call away
    # for the rest.
    SUMMARY_PREVIEW_LIMIT = 120

    # How many of those previews are rendered. The first ones by position are the
    # ones nearest delivery, which are the ones a caller weighing a follow-up
    # actually needs; the rest are counted.
    #
    # These two constants are the whole size bound, and it holds whatever the
    # queue does: at most MAX_SUMMARIZED previews of SUMMARY_PREVIEW_LIMIT
    # CHARACTERS each. Characters, not bytes — cutting on bytes would split a
    # multibyte codepoint — so the worst case is 4 bytes per character and the
    # section stays under ~3 KB even when every message is CJK. A megabyte of
    # queue renders in about 1.5 KB of ASCII.
    MAX_SUMMARIZED = 5

    module_function

    # `get_session`'s section.
    #
    # Scoped to `pending` — the same scope every other reader of "still going to
    # be sent" uses (Trigger's stall checks, the archive guard,
    # Session#process_next_enqueued_message!). Each other status is excluded for
    # its own reason: a `sent` row is destroyed on delivery, an `undelivered` one
    # is terminal, and a `processing` one has already been handed to
    # Sessions::InterruptService, so none of the three is something a caller can
    # still get ahead of. Reporting any of them as pending would recreate exactly
    # the confusion this section removes.
    #
    # Two queries, both bounded: one COUNT and one LIMITed select, over
    # (session_id, status). No preloading is needed and none is done, so this
    # stays cheap even though `get_session` is the most-called tool on the
    # surface.
    def summary_lines(session)
      scope = session.enqueued_messages.pending.ordered
      total = scope.count

      lines = [ "", "### Queued Messages" ]

      if total.zero?
        lines << "_Nothing is queued for this session: no message is waiting to be delivered to it._"
        return lines
      end

      lines << "- **Pending:** #{total} #{'message'.pluralize(total)} queued for this session and not yet delivered."
      lines << "- **Before you follow up:** the session has not seen these yet, and anything you send now lands BEHIND them. " \
               "Read them in full with `manage_enqueued_messages` (action `list`), and prefer its `update` / `delete` / " \
               "`reorder` actions to consolidate the queue over adding one more to it. " \
               "`send_now` (or `follow_up` with `force_immediate`) is how you get ahead of it."
      lines << ""

      # The rows, not the count, decide how many are left over: the session can
      # drain the queue between the COUNT above and this select, and "…and 3
      # more" under two bullets would be a worse answer than a smaller number.
      shown = scope.limit(MAX_SUMMARIZED).to_a
      shown.each do |message|
        lines << "- **Position #{message.position}** (ID #{message.id}, origin `#{message.origin}`, queued #{message.created_at.utc.iso8601}): " \
                 "#{compact_preview(message.content)}"
      end

      remaining = total - shown.size
      lines << "- _…and #{remaining} more, not shown._" if remaining.positive?
      lines << ""
      lines << "_Content above is truncated to #{SUMMARY_PREVIEW_LIMIT} characters per message. " \
               "Use `manage_enqueued_messages` to read any of them in full._"

      lines
    end

    # What the two surfaces that ADD to a queue report back — `action_session`
    # `follow_up` and `manage_enqueued_messages` `create`. A caller that just
    # became fourth in line finds out at the moment it happens rather than never.
    #
    # `queued_message` is what the caller's own message is, when it went into the
    # queue. Pass nil on the branches that DELIVERED it instead — an idle
    # session's direct send, or a `force_immediate` interrupt — where the depth
    # is other people's messages sitting behind the one just sent, and telling
    # the caller it was last in line would be the exact opposite of what
    # happened.
    #
    # Emitted only when something is actually pending, so the ordinary
    # send-to-an-empty-queue receipt is unchanged.
    def queue_depth_lines(session, queued_message: nil)
      depth = session.enqueued_messages.pending.count
      return [] if depth.zero?

      return delivered_ahead_lines(depth) if queued_message.nil?

      lines = [ "- **Queue depth:** #{depth} #{'message'.pluralize(depth)} now pending delivery to this session, " \
                "yours last at position #{queued_message.position}." ]
      if depth > 1
        ahead = depth - 1
        lines << "- **Note:** yours is not the only message waiting. The session works the queue in position order, " \
                 "so the #{ahead} ahead of yours #{ahead == 1 ? 'is' : 'are'} read first — list them with " \
                 "`manage_enqueued_messages` and consolidate with `update` / `delete` if one already says what yours says."
      end
      lines
    end

    # The full-queue preview. Cuts on length alone, leaving the text otherwise as
    # written — `manage_enqueued_messages` renders one message per bullet block,
    # where a newline in the content costs nothing.
    def preview(content)
      TextBudget.hard_truncate(content, CONTENT_PREVIEW_LIMIT)
    end

    # The one-line preview. Message content is written by whoever queued the
    # message — routinely another agent session — and here it is interpolated
    # into a single markdown bullet of the dump a self-inspecting session reads,
    # so a newline in it would open a second bullet and forge a line. Same
    # laundering the provenance sections already guard against, on the same
    # surface.
    def compact_preview(content)
      # squish first: it turns a newline into a space, where
      # sanitize_for_markdown_line would delete it and silently weld two words
      # together. Both run — squish flattens, the sanitizer neutralizes.
      TextBudget.hard_truncate(SessionHumanMessages.sanitize_for_markdown_line(content.to_s.squish), SUMMARY_PREVIEW_LIMIT)
    end

    # The depth reported to a caller whose own message was delivered rather than
    # queued. What is left is behind it, and the session sees it when the turn
    # this call just started comes to an end.
    def delivered_ahead_lines(depth)
      [
        "- **Still queued:** #{depth} other #{'message'.pluralize(depth)} #{depth == 1 ? 'is' : 'are'} still pending for " \
        "this session, behind the one you just delivered. The session has not seen #{depth == 1 ? 'it' : 'them'} yet — " \
        "#{depth == 1 ? 'it is' : 'they are'} delivered when the turn you just started ends. " \
        "Read #{depth == 1 ? 'it' : 'them'} with `manage_enqueued_messages` (action `list`)."
      ]
    end
    private_class_method :delivered_ahead_lines
  end
end
