# frozen_string_literal: true

module Mcp
  module Tools
    # The `precedence` / `place` argument pair, shared by every tool that can rank
    # a session in the spot queue — start_session and action_session.
    #
    # Two ways to say where something goes, and exactly one of them per call:
    #
    #   * `precedence` — an absolute integer on the scale the queue is ordered by.
    #   * `place` — a symbolic placement (SessionPrecedence::PLACES) the server
    #     resolves against the live queue as part of the same write.
    #
    # The symbolic form exists because the alternative is a read-then-write: an
    # agent asking `quick_search_sessions` for the current top and then writing a
    # few points above it can be overtaken between the two calls and land second
    # in the queue it meant to head. Resolution goes through
    # `Session.precedence_for_place`, which is the same helper the Ranked view's
    # demote button, the session detail page and the Quick Router already use, so
    # none of the surfaces can drift apart on what "the top of the queue" means.
    module PrecedenceArgument
      # Did the caller name a placement in either form? What action_session's two
      # ranking actions gate on.
      #
      # `place` is tested for presence and `precedence` for the key, because the
      # two arguments differ in what an explicit null means: a blank `place` is
      # "no placement asked for", while a null `precedence` on these actions is a
      # caller naming the argument and getting it wrong, which #absolute_precedence
      # rejects rather than silently ignoring. start_session reads a null
      # `precedence` as "say nothing" instead, so it tests its own condition.
      def precedence_named?(args)
        args.key?("precedence") || args["place"].present?
      end

      # The precedence a caller asked for, whichever form they used.
      #
      # @param args [Hash] raw string-keyed tool arguments
      # @param exclude [Session, nil] the session being placed. A session already
      #   sitting on top of the queue must not be measured against itself, or
      #   "put this at the head" would walk it SLOT_GAP higher on every call.
      #   nil for a session that does not exist yet.
      # @raise [ToolError] on an unknown placement, a non-integer precedence, a
      #   precedence out of range, or both arguments at once
      # @return [Integer]
      def resolved_precedence(args, exclude: nil)
        place = args["place"]
        return absolute_precedence(args["precedence"]) if place.blank?

        unless args["precedence"].nil?
          raise ToolError, '"place" and "precedence" are mutually exclusive — they are two answers to ' \
                           'the same question. Pass "place" to let the server work the value out against ' \
                           "the live queue, or \"precedence\" to name an absolute rank yourself."
        end

        unless SessionPrecedence::PLACES.include?(place.to_s)
          raise ToolError, "Unknown place: #{place.inspect}. Valid: #{SessionPrecedence::PLACES.join(', ')}."
        end

        Session.precedence_for_place(place.to_s, exclude ? Session.where.not(id: exclude.id) : nil)
      end

      private

      # An explicit rank. Bounded rather than free: the column is a 32-bit integer
      # and the reorder maths averages values, so a caller passing 10**12 would
      # break the ranked view's arithmetic rather than simply ranking very high.
      def absolute_precedence(value)
        unless value.is_a?(Integer) || value.to_s.match?(/\A-?\d+\z/)
          raise ToolError, "precedence must be an integer (got #{value.inspect})"
        end

        value = value.to_i
        unless value.between?(SessionPrecedence::MIN, SessionPrecedence::MAX)
          raise ToolError, "precedence must be between #{SessionPrecedence::MIN} and #{SessionPrecedence::MAX}"
        end

        value
      end
    end
  end
end
