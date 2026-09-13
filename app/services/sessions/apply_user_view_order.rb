# frozen_string_literal: true

module Sessions
  # "Here is the board, top to bottom" — applied as one write.
  #
  # Behind the `reorder_user_view` MCP tool, which is how the Reprioritize button's
  # session rewrites the dashboard's order. The human's own drag is NOT this: a
  # drag names two neighbours and moves ONE row, which is Sessions::ReorderPrecedence.
  # This is the bulk case, and the two are deliberately different shapes because
  # they answer different questions — "put this row here" versus "this is the
  # order".
  #
  # == Spacing rather than 1..N
  #
  # Precedence is an absolute scale that nothing renumbers (see SessionPrecedence).
  # A ranking written as N, N-1, N-2 would leave no room to drag a row between two
  # of them without a nudge on every drop, so the values are spaced GAP apart. The
  # human can then override any part of the agent's ranking by dragging, which is
  # the point: the button suggests an order, it does not impose one.
  #
  # == The listed rows land above everything else
  #
  # The top of the written range is GAP clear of the highest precedence in the
  # table, so a partial order — rank the ten rows the decision turns on, ignore the
  # tail — puts those ten above the unranked rest rather than interleaving with it.
  # Reading the maximum live, rather than from a high-water mark, is what keeps the
  # scale from inflating every time the button is pressed on a board whose top has
  # since been archived.
  class ApplyUserViewOrder
    class Error < StandardError; end

    # How far apart consecutive rows are placed. Wide enough that
    # Sessions::ReorderPrecedence can drop a dragged row between any two without
    # having to nudge a neighbour aside, which is the interaction this order has
    # to survive.
    GAP = 10

    # Bound on one call. The board itself is capped at USER_VIEW_LIMIT rows, and a
    # single UPDATE of that many is cheap; the cap is here so a malformed argument
    # cannot ask for an unbounded write.
    MAX_IDS = SessionsController::USER_VIEW_LIMIT

    # @!attribute ordered
    #   @return [Array<Array(Integer, Integer)>] [session_id, precedence] pairs, top first
    Result = Data.define(:ordered, :changed_count)

    # @param session_ids [Array<Integer>] the order, top first
    # @param reason [String, nil] one line for each moved session's log
    # @param actor [String] who asked, for the log line
    # @return [Result]
    def self.call(session_ids:, reason: nil, actor: "an agent")
      new(session_ids: session_ids, reason: reason, actor: actor).call
    end

    def initialize(session_ids:, reason: nil, actor: "an agent")
      @session_ids = session_ids
      @reason = reason
      @actor = actor
    end

    def call
      ids = validated_ids

      Session.transaction do
        # Locked in id order, the same discipline Sessions::ReorderPrecedence uses,
        # so a bulk reorder and a concurrent drag cannot deadlock against each
        # other.
        sessions = Session.where(id: ids).order(:id).lock.to_a
        found = sessions.index_by(&:id)

        missing = ids - found.keys
        raise Error, "No session with id #{missing.join(', ')}. Nothing was reordered." if missing.any?

        top = starting_precedence(ids)
        ordered = []
        changed = 0

        ids.each_with_index do |id, index|
          session = found.fetch(id)
          precedence = Session.clamp_precedence(top - (index * GAP))
          ordered << [ id, precedence ]

          next if session.precedence == precedence

          previous = session.precedence
          session.update!(precedence: precedence)
          session.logs.create!(
            content: log_line(precedence, previous, index),
            level: "info"
          )
          changed += 1
        end

        Result.new(ordered: ordered, changed_count: changed)
      end
    end

    private

    def validated_ids
      ids = Array(@session_ids).map(&:to_i).reject(&:zero?)
      raise Error, 'The "session_ids" list is empty.' if ids.empty?
      raise Error, "Too many session ids (maximum #{MAX_IDS})." if ids.size > MAX_IDS

      duplicates = ids.tally.select { |_, count| count > 1 }.keys
      raise Error, "Duplicate session id(s): #{duplicates.join(', ')}. Nothing was reordered." if duplicates.any?

      ids
    end

    # Where the top of the written range goes: clear of the highest precedence any
    # session the caller did NOT name is holding, with enough headroom below it for
    # the whole list, so the last placed row still sits at or above the unlisted
    # tail.
    #
    # Two exclusions, and both are load-bearing:
    #
    #   * **The listed sessions themselves.** Reading the table's overall maximum
    #     would include rows this very call is about to rewrite, so pressing
    #     Reprioritize twice on an unchanged board would write higher values the
    #     second time and higher again the third — a ratchet that inflates the
    #     scale for as long as someone keeps pressing. Measuring against the rows
    #     that are staying put makes a repeat of the same order a no-op.
    #   * **Archived sessions**, for the same reason
    #     SessionPrecedence.precedence_above_top_spot excludes them: a board whose
    #     top has since been trashed must not keep the scale up there with it.
    def starting_precedence(ids)
      top = Session.where.not(status: :archived).where.not(id: ids).maximum(:precedence)
      Session.clamp_precedence(top.to_i + (ids.size * GAP))
    end

    def log_line(precedence, previous, index)
      base = "Precedence set to #{precedence} (was #{previous}) — placed #{index + 1} on the User view by #{@actor}"
      @reason.present? ? "#{base}. Reason: #{@reason}" : base
    end
  end
end
