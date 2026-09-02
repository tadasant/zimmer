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
    # view's demote button, the session detail page's scheduling-class control,
    # the Quick Router's spot opt-in, and the MCP tools — comes through here, so
    # they cannot drift apart on what "the top of the queue" means.
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

    parent = genesis_parent_record
    self.precedence = parent ? self.class.clamp_precedence(parent.precedence.to_i + CHILD_BUMP) : DEFAULT
    @precedence_explicitly_set = false
  end
end
