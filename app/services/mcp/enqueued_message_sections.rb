# frozen_string_literal: true

module Mcp
  # The markdown rendering of what is sitting in a session's message queue.
  #
  # `manage_enqueued_messages` renders that queue in full — every status, every
  # message, paginated. `get_session` renders the part a caller needs *before* it
  # decides what to do with a session: how many messages are already pending, and
  # enough of each to recognise it by. `action_session` `follow_up` reports the
  # depth its own call left behind. One module, so those three cannot drift on
  # what "pending" means or where a preview is cut.
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
    MAX_SUMMARIZED = 5

    module_function

    # `get_session`'s section.
    #
    # Scoped to `pending` — the same scope every other reader of "still going to
    # be sent" uses (Trigger's stall checks, the archive guard,
    # Session#process_next_enqueued_message!). A `sent` row is destroyed on
    # delivery and an `undelivered` one is terminal, so reporting either as
    # pending would recreate exactly the confusion this section removes.
    #
    # Two queries, both bounded: one COUNT and one LIMITed select. No preloading
    # is needed and none is done, so this stays cheap even though `get_session`
    # is the most-called tool on the surface.
    def summary_lines(session)
      scope = session.enqueued_messages.pending.ordered
      total = scope.count

      lines = [ "", "### Queued Messages" ]

      if total.zero?
        lines << "_Nothing is queued for this session: no message is waiting to be delivered to it._"
        return lines
      end

      lines << "- **Pending:** #{total} #{pluralize_messages(total)} queued for this session and not yet delivered."
      lines << "- **Before you follow up:** the session has not seen these yet, and anything you send now lands BEHIND them. " \
               "Read them in full with `manage_enqueued_messages` (action `list`), and prefer its `update` / `delete` / " \
               "`reorder` actions to consolidate the queue over adding one more to it. " \
               "`send_now` (or `follow_up` with `force_immediate`) is how you get ahead of it."
      lines << ""

      scope.limit(MAX_SUMMARIZED).each do |message|
        lines << "- **Position #{message.position}** (ID #{message.id}, origin `#{message.origin}`, queued #{message.created_at.iso8601}): " \
                 "#{compact_preview(message.content)}"
      end

      remaining = total - MAX_SUMMARIZED
      if remaining.positive?
        lines << "- _…and #{remaining} more, not shown._"
      end
      lines << "_Content above is truncated to #{SUMMARY_PREVIEW_LIMIT} characters per message. " \
               "Use `manage_enqueued_messages` to read any of them in full._"

      lines
    end

    # What `action_session` `follow_up` (and the queueing branch of
    # `manage_enqueued_messages`) reports back: the depth the caller's own message
    # just landed in. A caller that has become fourth in line finds out at the
    # moment it happens rather than never.
    #
    # Emitted only when something is actually pending, so the ordinary
    # send-to-an-idle-session receipt is unchanged.
    def queue_depth_lines(session)
      depth = session.enqueued_messages.pending.count
      return [] if depth.zero?

      lines = [ "- **Queue depth:** #{depth} #{pluralize_messages(depth)} now pending delivery to this session." ]
      if depth > 1
        lines << "- **Note:** yours is not the only message waiting. The session works the queue in position order, " \
                 "so an earlier one is read first — list the queue with `manage_enqueued_messages` and consolidate " \
                 "with `update` / `delete` if an earlier message already says what yours says."
      end
      lines
    end

    # The full-queue preview. Cuts on length alone, leaving the text otherwise as
    # written — `manage_enqueued_messages` renders one message per bullet block,
    # where a newline in the content costs nothing.
    def preview(content)
      truncate(content.to_s, CONTENT_PREVIEW_LIMIT)
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
      truncate(SessionHumanMessages.sanitize_for_markdown_line(content.to_s.squish), SUMMARY_PREVIEW_LIMIT)
    end

    def truncate(text, limit)
      text.length > limit ? "#{text[0, limit]}..." : text
    end

    def pluralize_messages(count)
      count == 1 ? "message" : "messages"
    end
  end
end
