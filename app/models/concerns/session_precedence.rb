# frozen_string_literal: true

# Where a session sits in the spot queue.
#
# == Absolute, not ordinal
#
# `precedence` is an absolute scale: higher is handled sooner, and 100000 comes
# before 50. It is deliberately NOT a 1..N rank — nothing renumbers, nothing
# compacts, and two sessions may hold the same value. Sparse values are the whole
# point, because they leave room to slot a session between two others without
# rewriting the column.
#
# Ties break on `created_at` ascending, so equal precedence means "oldest first"
# rather than "whichever the planner felt like".
#
# == It lives on every session
#
# Only spot sessions are *ordered* by it today, but every session carries one. A
# priority session demoted to spot has to land somewhere sensible, and a spot
# session promoted to priority has to keep its place for when it is demoted back;
# a column populated for half the rows would lose that on every round trip.
#
# == Children sit just above their parent
#
# A session spawned by another inherits its parent's precedence plus
# CHILD_BUMP. A tree of work then stays contiguous — the child a session spawns
# to finish its own job runs before unrelated work that happens to be queued
# beneath it, rather than sinking to the bottom of the queue. Callers that know
# better (MCP `start_session`, the REST API, a trigger's predefined value) name
# their own and are never overridden.
#
# One kind of spawn is not a child in that sense and does not inherit: a
# status-summary fork, which is Zimmer writing a blurb about the source rather
# than work continuing from it. See #precedence_parent.
module SessionPrecedence
  extend ActiveSupport::Concern

  # What a session with nothing to inherit from starts at. Zero rather than a
  # midpoint, because the scale is unbounded in both directions and "nobody has
  # said anything" is the value the whole queue is measured against.
  DEFAULT = 0

  # How far above its parent a spawned session lands. One point: "slightly
  # higher" is the intent — the child goes first, and a chain of them does not
  # drift far enough to jump the work its root was already ranked beneath.
  CHILD_BUMP = 1

  # The gap opened when something is slotted at the top or the bottom of the
  # queue (a demotion, a drag past the last row). A few points rather than one,
  # so the next thing to land there still has room between them.
  SLOT_GAP = 5

  # A symbolic placement a caller can ask for instead of naming a number, so the
  # server works out the value against the queue as it stands at the moment of
  # the write. The point is not brevity: a caller that reads the current top and
  # then writes a value a few points above it can be overtaken between the two,
  # and lands second in the queue it meant to head.
  PLACE_TOP_OF_SPOT = "top_of_spot"

  # Every placement the surfaces accept. One today; the list is what the HTML
  # controller, the MCP tools and their schemas all validate against, so a second
  # one is added here rather than in four places.
  PLACES = [ PLACE_TOP_OF_SPOT ].freeze

  # What every surface says when a caller sends both a placement and an absolute
  # rank. Here rather than in each surface for the same reason PLACES is: the
  # refusal is one rule, and a caller that hits it over REST and then over MCP
  # should not have to work out that it read two different sentences.
  BOTH_PLACE_AND_PRECEDENCE = '"place" and "precedence" are mutually exclusive — they are two ' \
    'answers to the same question. Pass "place" to let the server work the value out against the ' \
    'live queue, or "precedence" to name an absolute rank yourself.'

  # Bounds. Postgres `integer` is 32-bit, and the reorder maths adds and averages
  # values, so the accepted range is kept an order of magnitude clear of the
  # column's own limit. Nothing legitimate needs a billion.
  MIN = -1_000_000_000
  MAX = 1_000_000_000

  included do
    validates :precedence,
      numericality: {
        only_integer: true,
        greater_than_or_equal_to: MIN,
        less_than_or_equal_to: MAX
      },
      allow_nil: false

    before_validation :assign_precedence, on: :create

    # The spot queue's order: highest precedence first, oldest first within a tie.
    scope :ranked, -> { order(precedence: :desc, created_at: :asc, id: :asc) }
  end

  class_methods do
    # The precedence to give something being put at the TOP of the spot queue:
    # a few points above the highest spot session currently in `scope`.
    #
    # Reads the live maximum rather than a stored high-water mark, so a queue
    # whose top has since been archived does not keep inflating.
    #
    # @param scope [ActiveRecord::Relation] the population to land above
    # @return [Integer]
    def precedence_above_top_spot(scope = nil)
      # The archived exclusion is applied to whatever the caller passed, not only
      # to the default. It is the whole guarantee of the method — a queue whose
      # top has since been archived must not keep inflating — and applying it to
      # one branch would void it on the only path that passes a scope.
      top = (scope || all).where.not(status: :archived).spot.maximum(:precedence)
      return DEFAULT + SLOT_GAP if top.nil?

      clamp_precedence(top + SLOT_GAP)
    end

    # Resolve a symbolic placement to a concrete precedence, against the queue as
    # it stands right now. Every surface that accepts a placement — the Ranked
    # view's demote button, the Quick Router's spot opt-in, and the MCP tools —
    # comes through here, so they cannot drift apart on what "the top of the
    # queue" means. (They may still differ on *when* they offer a placement at
    # all: the demote button only sends one on a demotion, while an MCP caller
    # that names one means it whichever class it is moving the session to.)
    #
    # It is a read followed by a separate write, not a lock: two callers placing
    # at the top at the same instant both read the same maximum and both land on
    # the same value, where `ranked` breaks the tie on created_at. That is a far
    # narrower window than a caller reading the top in one request and writing in
    # another, and it is not zero.
    #
    # @param place [String] one of PLACES
    # @param scope [ActiveRecord::Relation, nil] the population to place within
    # @raise [ArgumentError] if the placement is not one this knows
    # @return [Integer]
    def precedence_for_place(place, scope = nil)
      case place.to_s
      when PLACE_TOP_OF_SPOT then precedence_above_top_spot(scope)
      else raise ArgumentError, "Unknown precedence placement: #{place.inspect}. Valid: #{PLACES.join(', ')}"
      end
    end

    # Hold a computed value inside the accepted range. The reorder maths can run
    # off either end (a drag below a session already at MIN), and a clamp is a
    # better answer there than a validation error the user cannot act on.
    def clamp_precedence(value)
      value.to_i.clamp(MIN, MAX)
    end
  end

  # The precedence THIS session should take at a symbolic placement — the form
  # every surface wants when it is re-placing a session that is already in the
  # queue (MCP's `action_session`, `PATCH /api/v1/sessions/:id`).
  #
  # Two adjustments over the class method, both about a session measuring itself:
  #
  # 1. It is excluded from the population, so "put this at the head" applied to
  #    the row already on top does not walk it SLOT_GAP higher every call. Same
  #    exclusion the Ranked view's demote button applies.
  # 2. The result is floored at the value the session already holds. Without
  #    that, (1) overshoots in the other direction: a session on top at 1000 with
  #    a runner-up at 10 would be rewritten to 15 — still the head of the spot
  #    queue, but now beneath a priority session carrying 500 that would outrank
  #    it on a later demotion. "Put this first" is never a request to lower a
  #    rank, so a session that is already first keeps its number.
  #
  # @param place [String] one of PLACES
  # @raise [ArgumentError] if the placement is not one this knows
  # @return [Integer]
  def precedence_for_place(place)
    resolved = self.class.precedence_for_place(place, self.class.where.not(id: id))
    [ resolved, precedence.to_i ].max
  end

  # Records that a caller named a value, so create-time inheritance leaves it
  # alone — an explicit 0 is a choice and must not be re-derived. ActiveRecord's
  # own load path does not go through this writer, so it only ever fires for a
  # deliberate assignment.
  #
  # A nil (or blank) assignment means "say nothing" rather than NULL: the column
  # is NOT NULL, and a form that submits an empty field is clearing the value
  # back to the default, not asking for an unsaveable row.
  #
  # `write_attribute` rather than `super`: ActiveRecord generates its attribute
  # writers lazily, so at the moment this override first runs there may be no
  # superclass method to call yet.
  def precedence=(value)
    if value.nil? || (value.respond_to?(:strip) && value.strip.empty?)
      @precedence_explicitly_set = false
      write_attribute(:precedence, DEFAULT)
    else
      @precedence_explicitly_set = true
      write_attribute(:precedence, value)
    end
  end

  private

  # A spawned session lands just above the session that spawned it; everything
  # else starts at DEFAULT.
  def assign_precedence
    return if @precedence_explicitly_set

    parent = precedence_parent
    self.precedence = parent ? self.class.clamp_precedence(parent.precedence.to_i + CHILD_BUMP) : DEFAULT
    @precedence_explicitly_set = false
  end

  # The session this one takes its rank from, or nil for "nobody has said
  # anything".
  #
  # A STATUS-SUMMARY FORK HAS NO SUCH SESSION. CHILD_BUMP is a statement about
  # work: the child a session spawns to finish its own job goes first, so a tree
  # of work stays contiguous. A summary fork is not doing the source's job — it
  # is Zimmer writing a blurb ABOUT the source, and inheriting the bump landed it
  # one rank above the very session it was summarizing (#712). The queue an
  # operator arranged then had Zimmer's own bookkeeping at the head of it.
  #
  # DEFAULT rather than the source's own value: the two would tie, and `ranked`
  # breaks a tie on `created_at`, so a fork would still be ordered against real
  # work rather than out of the way of it. Zero is what the scale means by
  # "nobody has said anything", which is the truth about a fork — no operator
  # ever placed it.
  #
  # Only the SUMMARY fork. A fork an operator made by hand is a working session
  # continuing the source's line of work, and it keeps the bump.
  def precedence_parent
    return nil if status_summary_fork?

    genesis_parent_record
  end
end
