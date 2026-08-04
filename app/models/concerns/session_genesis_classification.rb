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
# Class is NOT denormalized onto the row. `#priority_class` derives from the
# stored genesis through SessionGenesis every time it is asked, so promoting a
# genesis kind reclassifies every existing session of that genesis at once. That
# is what "change a genesis to priority" has to mean — a stored class would only
# ever apply to sessions created after the click.
module SessionGenesisClassification
  extend ActiveSupport::Concern

  included do
    validates :genesis,
      inclusion: { in: -> { SessionGenesis::KEYS }, message: "%{value} is not a known genesis" },
      allow_nil: true

    before_validation :assign_genesis, on: :create

    scope :with_genesis, ->(keys) { where(genesis: Array(keys).map(&:to_s)) }

    # Rows whose genesis currently resolves to the given class. Resolved through
    # SessionGenesis so a promoted kind moves its sessions immediately, and
    # written as a key list so it stays a plain indexed IN () on `genesis`.
    scope :priority_classified, ->(klass) {
      keys = SessionGenesis.keys_classified(klass)
      # A NULL genesis has not been backfilled yet. Treat it as unknown, which
      # classifies priority — the same fail-safe the backfill uses.
      if keys.include?(SessionGenesis::DEFAULT_KEY)
        where(genesis: keys).or(where(genesis: nil))
      else
        where(genesis: keys)
      end
    }

    scope :spot, -> { priority_classified(SessionGenesis::SPOT) }
    scope :priority, -> { priority_classified(SessionGenesis::PRIORITY) }
  end

  class_methods do
    # Count of sessions per genesis, for the settings table. Archived rows are
    # excluded so the number describes live work, not all history.
    def genesis_counts
      counts = where.not(status: :archived).group(:genesis).count
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

  # "spot" or "priority", resolved live. Pass `overrides` when classifying many
  # sessions at once to avoid re-reading AppSetting per row.
  def priority_class(overrides = nil)
    SessionGenesis.effective_class(genesis_key, overrides)
  end

  def spot?(overrides = nil)
    priority_class(overrides) == SessionGenesis::SPOT
  end

  def priority?(overrides = nil)
    priority_class(overrides) == SessionGenesis::PRIORITY
  end

  private

  def assign_genesis
    return if genesis.present?

    self.genesis = inherited_genesis || SessionGenesis::DEFAULT_KEY
  end

  def inherited_genesis
    parent = genesis_parent
    return nil unless parent

    parent.genesis.presence
  end

  # The session this one descends from: the spawn edge first, then the fork
  # marker, which is the only lineage a fork records.
  def genesis_parent
    if parent_session_id.present?
      return Session.select(:id, :genesis).find_by(id: parent_session_id)
    end

    forked_from = (metadata || {})["forked_from_session_id"]
    return nil if forked_from.blank?

    Session.select(:id, :genesis).find_by(id: forked_from)
  end
end
