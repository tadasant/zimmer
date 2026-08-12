# frozen_string_literal: true

# Assigns a session's genesis at creation and answers spot/priority for it.
#
# The assignment rule is three lines long and the ordering is the whole design:
#
#   1. An explicitly declared genesis wins. The entry points that KNOW where the
#      work came from say so — the web controllers stamp `web_ui`, the trigger
#      jobs stamp the kind their condition maps to. This must outrank inheritance
#      or the chat bubble would take its genesis from whatever session the user
#      happened to have open, and a human's message would inherit spot.
#
#   2. Otherwise inherit the parent's genesis. This is the case for every agent
#      spawn: MCP start_session and the REST API declare nothing and pass a
#      parent, so the spawned session belongs to the same line of work. Forks
#      inherit through `metadata["forked_from_session_id"]`, which is the only
#      edge a fork has.
#
#   3. Otherwise `unknown`. The two machine surfaces that can create a parentless
#      session — POST /api/v1/sessions and MCP start_session — stamp `api`
#      themselves, so reaching this fallback means a path Zimmer does not account
#      for. `unknown` classifies priority, so an unaccounted-for path runs rather
#      than being silently throttled.
#
# == Where the spot/priority class comes from
#
# `#priority_class` answers two questions in order:
#
#   1. Did anyone SAY, for this session? `scheduling_class` on the row holds an
#      explicit choice and nothing overrides it. Three things write it: a caller
#      naming one at creation (MCP start_session, POST /api/v1/sessions), a
#      trigger that carries a selector of its own, and inheritance from a parent
#      that had one. The column is NULL on every session where nobody has
#      spoken, which is most of them.
#
#   2. Otherwise derive it from the genesis, live, through SessionGenesis — the
#      original contract. A `web_ui`/`api`/`unknown` session still reclassifies
#      the instant its kind is moved in Settings, because nothing is stored on
#      the row to pin it.
#
# The column is deliberately sparse rather than stamped on every session. Storing
# the resolved class everywhere would freeze the shipped defaults into history
# and make a settings change apply only to sessions created after the click;
# storing only deliberate choices keeps both properties — an explicit request is
# honored forever, and everything else still follows policy.
#
# A trigger's selector is read at fire time, not at start time, so changing it
# reclassifies the trigger's FUTURE sessions only. Sessions it already spawned —
# including ones still `waiting` behind the spot gate — keep the class they were
# created with; move an individual one with action_session's `change_scheduling_class`.
module SessionGenesisClassification
  extend ActiveSupport::Concern

  included do
    validates :genesis,
      inclusion: { in: -> { SessionGenesis::KEYS }, message: "%{value} is not a known genesis" },
      allow_nil: true
    validates :scheduling_class,
      inclusion: { in: -> { SessionGenesis::CLASSES }, message: "%{value} is not a known scheduling class" },
      allow_nil: true

    before_validation :normalize_scheduling_class
    before_validation :assign_genesis, on: :create
    before_validation :assign_scheduling_class, on: :create

    scope :with_genesis, ->(keys) { where(genesis: Array(keys).map(&:to_s)) }

    # Rows that currently resolve to the given class: the ones that said so
    # outright, plus the ones that say nothing and whose genesis resolves there.
    # Written as key lists so both halves stay plain indexed IN ()s.
    scope :priority_classified, ->(klass) {
      keys = SessionGenesis.keys_classified(klass)
      derived = where(scheduling_class: nil)
      # A NULL genesis has not been backfilled yet. Treat it as unknown, which
      # classifies priority — the same fail-safe the backfill uses.
      derived = if keys.include?(SessionGenesis::DEFAULT_KEY)
        derived.where(genesis: keys).or(where(scheduling_class: nil).where(genesis: nil))
      else
        derived.where(genesis: keys)
      end

      where(scheduling_class: klass.to_s).or(derived)
    }

    scope :spot, -> { priority_classified(SessionGenesis::SPOT) }
    scope :priority, -> { priority_classified(SessionGenesis::PRIORITY) }
  end

  class_methods do
    # Count of sessions per genesis, for the settings table. Archived rows are
    # excluded so the number describes live work, not all history, and rows that
    # named their own class are excluded too — moving a genesis kind does not
    # touch them, so counting them would overstate what a click does.
    def genesis_counts
      counts = where.not(status: :archived).where(scheduling_class: nil).group(:genesis).count
      # `priority_classified` folds a NULL genesis into the default key, so the
      # counts have to as well — otherwise an unbackfilled row lands under a nil
      # key nothing renders and the "N sessions reclassified" figure is short.
      nulls = counts.delete(nil).to_i
      counts[SessionGenesis::DEFAULT_KEY] = counts[SessionGenesis::DEFAULT_KEY].to_i + nulls if nulls.positive?
      counts
    end

    # Live sessions whose stored genesis is `key`, counting NULL rows under the
    # default key for the same reason.
    def genesis_count_for(key)
      genesis_counts[key.to_s].to_i
    end
  end

  # The stored genesis, never nil — an unbackfilled row reads as "unknown".
  def genesis_key
    genesis.presence || SessionGenesis::DEFAULT_KEY
  end

  def genesis_label
    SessionGenesis.label(genesis_key)
  end

  # "spot" or "priority": what this session said, else what its genesis says.
  # Pass `overrides` when classifying many sessions at once to avoid re-reading
  # AppSetting per row.
  def priority_class(overrides = nil)
    scheduling_class.presence || SessionGenesis.effective_class(genesis_key, overrides)
  end

  # True when the class was chosen for this session rather than derived, which is
  # what the UI and MCP show to explain why a session's class does not match its
  # genesis's.
  def scheduling_class_explicit?
    scheduling_class.present?
  end

  # Where the class came from, as prose for one session.
  def scheduling_class_source(overrides = nil)
    return "set on this session" if scheduling_class_explicit?

    "#{SessionGenesis.label(genesis_key)} default (#{SessionGenesis.effective_class(genesis_key, overrides)})"
  end

  def spot?(overrides = nil)
    priority_class(overrides) == SessionGenesis::SPOT
  end

  def priority?(overrides = nil)
    priority_class(overrides) == SessionGenesis::PRIORITY
  end

  private

  # An unknown or blank value is not a validation failure at every call site —
  # a form's "derive it" option submits "". Only a value that names a real class
  # is stored; anything else that is blank becomes NULL, and a non-blank unknown
  # is left alone so the inclusion validation can reject it.
  def normalize_scheduling_class
    self.scheduling_class = nil if scheduling_class.blank?
  end

  def assign_genesis
    return if genesis.present?

    self.genesis = inherited_genesis || SessionGenesis::DEFAULT_KEY
  end

  # An explicit class travels down a lineage the same way genesis does: a router
  # told to run a batch as spot spawns children that are also spot, without every
  # spawn call having to repeat it. Nothing is inherited when the parent never
  # named one — the child derives from the genesis it inherited instead.
  def assign_scheduling_class
    return if scheduling_class.present?

    self.scheduling_class = genesis_parent_record&.scheduling_class.presence
  end

  def inherited_genesis
    genesis_parent_record&.genesis.presence
  end

  # The session this one descends from: the spawn edge first, then the fork
  # marker, which is the only lineage a fork records. Memoized because genesis
  # and scheduling class both inherit from it and neither should cost its own
  # query. Memoized on `defined?`, because "no parent" is a real answer that has
  # to be cached too.
  def genesis_parent_record
    return @genesis_parent_record if defined?(@genesis_parent_record)

    @genesis_parent_record = genesis_parent
  end

  def genesis_parent
    if parent_session_id.present?
      return Session.select(:id, :genesis, :scheduling_class).find_by(id: parent_session_id)
    end

    forked_from = (metadata || {})["forked_from_session_id"]
    return nil if forked_from.blank?

    Session.select(:id, :genesis, :scheduling_class).find_by(id: forked_from)
  end
end
