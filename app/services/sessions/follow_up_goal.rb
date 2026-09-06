# frozen_string_literal: true

module Sessions
  # The rule for applying a *goal* that arrived alongside a follow-up prompt.
  #
  # Delivery of the prompt itself has been shared since #260 — `Session#deliver_follow_up!`
  # — but the goal rule that runs beside it was written out longhand at every entry
  # surface: the web controller's `follow_up`, `Api::V1::SessionsController#follow_up`,
  # the MCP `follow_up` action's `direct_follow_up`, and `EnqueuedMessageProcessorService`
  # when it claims a queued message. Four copies of one sentence, each with its own
  # wording for the log line it writes. This is that sentence, once (#105).
  #
  # The rule:
  #
  # - A goal is normalized first — stripped, and blank becomes `nil`. `"  "` and `""`
  #   and absent are all the same input.
  # - A non-blank goal that differs from the session's current goal **overwrites** it
  #   and logs that it did.
  # - A blank goal **preserves** whatever goal the session already has. A follow-up
  #   with no goal is not a request to clear one; clearing is its own operation
  #   (`PATCH /api/v1/sessions/:id`, the web `update_goal` action, the MCP
  #   `change_goal` action).
  #
  # The web UI is the one deliberate exception, and it is a real one rather than a
  # drift: its follow-up form always submits the goal field, so it can tell "the human
  # emptied the box" (`params.key?(:goal)` with a blank value — a clear) from "no goal
  # was involved" (no `:goal` key at all — the controller substitutes the session's
  # existing goal before calling here). Callers that can make that distinction pass
  # `clear_when_blank: true`; the API, MCP and queue paths cannot, and do not.
  #
  # Stateless class methods rather than the `self.call` -> `new(...).call` shape most
  # of app/services/sessions/ uses, and deliberately so: this is three independent
  # operations a caller reaches for at three different moments — parse, refuse, apply
  # — not one operation with collaborators worth holding in an instance.
  # Sessions::AttachmentDescriptors is the same shape for the same reason.
  class FollowUpGoal
    # What each surface calls the thing the goal arrived on, spliced into the log
    # line. The wording is per-source on purpose — a reader of a session's log wants
    # to know whether the goal came in with a typed follow-up or off a message that
    # had been sitting in the queue — but it lives here rather than at four call
    # sites, so the four cannot drift apart again.
    LOG_PHRASES = {
      web_follow_up: "for this follow-up",
      follow_up: "from follow-up",
      enqueued_message: "from enqueued message"
    }.freeze

    class << self
      # Strip a raw goal input down to the value the rule operates on.
      #
      # @param raw [String, nil] whatever the surface received — a param, an MCP
      #   argument, an `EnqueuedMessage#goal` column
      # @return [String, nil] the stripped goal, or nil when it was blank
      def normalize(raw)
        raw.to_s.strip.presence
      end

      # @param goal [String, nil] a normalized goal
      # @return [Boolean] true when the goal exceeds `Session::GOAL_MAX_LENGTH`
      #
      # Every surface rejects an over-long goal *before* any branch mutates state, so
      # it fails the same way whether the message is queued, interrupted in, or sent
      # directly — and never after the prompt has already been delivered. Only the
      # phrasing of the refusal is the surface's own.
      def too_long?(goal)
        goal.present? && goal.to_s.length > Session::GOAL_MAX_LENGTH
      end

      # Apply the rule to a session.
      #
      # @param session [Session]
      # @param goal [String, nil] the normalized goal that came with the follow-up
      # @param source [Symbol] a key of {LOG_PHRASES} — which surface this arrived on
      # @param clear_when_blank [Boolean] true only for a surface that can distinguish
      #   an emptied goal field from an absent one (the web follow-up form)
      # @param also_update [Hash] other attributes to write in the same `update!`.
      #   The API and MCP direct branches pass `prompt:` here so the goal write and
      #   the prompt write stay the single UPDATE they have always been, rather than
      #   becoming two saves inside the caller's transaction.
      # @param log_with [#call, nil] how to write the log line, given its content.
      #   Defaults to a plain `session.logs.create!`. EnqueuedMessageProcessorService
      #   passes its own `add_log`, which buffers the line when a turn is batching
      #   them and retries the write when it is not — this service decides *what*
      #   the line says, never how the caller persists it.
      # @return [Boolean] true when the session's goal was written
      def apply!(session:, goal:, source:, clear_when_blank: false, also_update: {}, log_with: nil)
        phrase = LOG_PHRASES.fetch(source)

        changed = if clear_when_blank
          goal != session.goal
        else
          goal.present? && goal != session.goal
        end

        attributes = also_update.dup
        attributes[:goal] = goal if changed
        session.update!(attributes) if attributes.any?

        if changed
          content = "Goal #{goal.present? ? 'updated' : 'removed'} #{phrase}"
          if log_with
            log_with.call(content)
          else
            session.logs.create!(content: content, level: "info")
          end
        end

        changed
      end
    end
  end
end
