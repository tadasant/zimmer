# frozen_string_literal: true

module Sessions
  # Turns "this row was dropped between those two rows" into a precedence value.
  #
  # The rule the ranked view promises:
  #
  #   * Dropped between two sessions → the MIDPOINT of their two values.
  #   * Dropped between two ADJACENT values, where no midpoint exists → nudge the
  #     neighbours apart by one each to make space, then take the midpoint of the
  #     widened gap.
  #   * Dropped at the top or the bottom → SLOT_GAP clear of the single neighbour.
  #   * Dropped into an empty queue → the default.
  #
  # The nudge is what keeps an integer column usable without a renumbering pass.
  # Two adjacent values (12, 11) become (13, 11) and the dropped row takes 12 —
  # one write more than the simple case, and no global compaction ever.
  #
  # A nudge can push a neighbour onto the value of the row beyond it. That is
  # left alone deliberately: equal precedence is legal, `ranked` breaks the tie on
  # `created_at`, and cascading the nudge upward would turn one drag into an
  # unbounded write. The next drag into that spot nudges again and separates them.
  #
  # Every write happens in one transaction with the rows locked in id order, so
  # two drags landing at once cannot interleave into a half-applied reorder.
  class ReorderPrecedence
    # What the reorder did, for the JSON the ranked view applies optimistically.
    # `changes` carries every row whose value moved — the dragged session and any
    # nudged neighbour — so the client can correct the numbers it guessed.
    Result = Data.define(:session, :precedence, :changes)

    class Error < StandardError; end

    # @param session [Session] the dragged session
    # @param above [Session, nil] the session immediately ABOVE the drop position
    #   (higher precedence), nil when dropped at the top
    # @param below [Session, nil] the session immediately BELOW the drop position
    #   (lower precedence), nil when dropped at the bottom
    def self.call(session:, above: nil, below: nil)
      new(session: session, above: above, below: below).call
    end

    def initialize(session:, above: nil, below: nil)
      @session = session
      @above = above
      @below = below
    end

    def call
      raise Error, "A session cannot be dropped next to itself" if neighbour_is_self?

      changes = {}

      Session.transaction do
        lock_rows!

        target = compute(changes)
        if @session.precedence != target
          @session.update!(precedence: target)
          changes[@session.id] = target
        end
      end

      Result.new(session: @session, precedence: @session.precedence, changes: changes)
    end

    private

    attr_reader :above, :below

    def neighbour_is_self?
      [ above, below ].compact.any? { |neighbour| neighbour.id == @session.id }
    end

    # Lock every row this reorder may write, in a stable order. Ascending id
    # rather than list order: two concurrent drags sharing a neighbour would
    # otherwise take the same two locks in opposite orders and deadlock.
    def lock_rows!
      ids = [ @session, above, below ].compact.map(&:id).uniq.sort
      Session.where(id: ids).order(:id).lock.load
      [ @session, above, below ].compact.each(&:reload)
    end

    def compute(changes)
      return SessionPrecedence::DEFAULT if above.nil? && below.nil?
      return Session.clamp_precedence(below.precedence + SessionPrecedence::SLOT_GAP) if above.nil?
      return Session.clamp_precedence(above.precedence - SessionPrecedence::SLOT_GAP) if below.nil?

      high = above.precedence
      low = below.precedence

      # The list is ordered highest-first, so a well-formed drop has high >= low.
      # A client that sends them the other way round (a stale DOM, a hand-rolled
      # request) gets the pair read in the order the data actually supports rather
      # than a midpoint outside the gap it names.
      high, low = low, high if high < low

      # No room between them: widen the gap by one on each side, then take the
      # middle of what is now at least three wide.
      if high - low < 2
        high = Session.clamp_precedence(high + 1)
        low = Session.clamp_precedence(low - 1)
        apply_nudge(above, high, changes)
        apply_nudge(below, low, changes)
      end

      midpoint(high, low)
    end

    def apply_nudge(session, value, changes)
      return if session.precedence == value

      session.update!(precedence: value)
      changes[session.id] = value
    end

    # Integer midpoint, rounded toward the LOW end so a dragged row never lands
    # on the value of the neighbour above it (a tie there would read as "above
    # the row it was dropped under" once created_at breaks it).
    def midpoint(high, low)
      Session.clamp_precedence((high + low).fdiv(2).floor)
    end
  end
end
