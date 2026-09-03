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
    # `Session.precedence_for_place`, the same helper the Ranked view's demote
    # button and the Quick Router already use, so the surfaces cannot drift apart
    # on what "the top of the queue" means.
    #
    # == What counts as "the caller named this argument"
    #
    # The two arguments read an explicit null differently, and deliberately.
    # `place` is an enum, so a blank one is not a placement — it is the argument
    # left out. `precedence` is a scalar whose whole range is meaningful, so
    # anything other than a JSON null is a value the caller chose and is worth
    # validating rather than silently dropping. The two predicates below then
    # differ only in what a null `precedence` means, which is the one thing the
    # tools themselves disagree about: on action_session's ranking actions naming
    # the key at all is a claim, while start_session reads a null as "say
    # nothing" and leaves the just-above-the-parent inheritance in place.
    module PrecedenceArgument
      private

      # action_session's reading: naming the key at all is a claim.
      def precedence_named?(args)
        args.key?("precedence") || args["place"].present?
      end

      # start_session's reading: a null `precedence` is "say nothing".
      def precedence_given?(args)
        !args["precedence"].nil? || args["place"].present?
      end

      # The precedence a caller asked for, whichever form they used.
      #
      # @param args [Hash] raw string-keyed tool arguments
      # @param exclude [Session, nil] the session being placed, or nil for one
      #   that does not exist yet. See #placed_precedence for what it does.
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

        placed_precedence(place.to_s, exclude)
      end

      # Resolve a placement for a session that may already be in the queue.
      #
      # A session that exists places itself — `Session#precedence_for_place`
      # carries the two adjustments a re-placement needs (excluding the row from
      # its own population, and never lowering a rank), and it is the same method
      # the REST API's PATCH goes through. One that does not exist yet has
      # nothing to exclude and no rank to keep, so it takes the class method.
      def placed_precedence(place, session)
        return Session.precedence_for_place(place) unless session

        session.precedence_for_place(place)
      end

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
