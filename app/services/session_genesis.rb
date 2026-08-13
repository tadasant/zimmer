# frozen_string_literal: true

# The genesis taxonomy, and the spot/priority class each kind resolves to.
#
# == Genesis
#
# A session's *genesis* is where its line of work ultimately came from — not who
# physically inserted the row. A router session spawned to carry out something a
# human typed into the web app has a genesis of `web_ui`, because that is where
# the work originated; the fact that an agent made the API call is a detail of
# how, not of where from. Session#assign_genesis implements that by inheriting a
# parent's genesis whenever the creator does not declare one, so an entire
# lineage shares a single genesis.
#
# That inheritance is what makes the classification safe to act on. Holding a
# router session spawned from a human's request would strand that request
# half-done; holding one spawned by the issue-work gate is exactly the intent.
# Both fall out of the same rule.
#
# == Spot vs priority
#
# `priority` work runs whenever it is ready. `spot` work runs only while there is
# forecast headroom in the Claude Code quota windows (see SpotGateService); when
# there is not, it is deferred and started later.
#
# The defaults below are policy, not physics — but where you change them depends
# on the kind, and the split is deliberate:
#
#   - Five of the eight kinds (`slack`, `github_issue`, `github_label`,
#     `schedule`, `ao_event`) are restatements of trigger condition types. Their
#     selector lives on the Trigger row (Trigger#scheduling_class), so one noisy
#     `slack` trigger can be spot without demoting the eleven others that carry a
#     human waiting for an answer. `#trigger_backed?` marks them.
#
#   - The other three (`web_ui`, `api`, `unknown`) have no trigger behind them,
#     so they keep a per-kind setting in AppSetting#genesis_class_overrides.
#     SETTABLE_KEYS is that list, and it is the only thing /quotas and
#     `action_spot_policy` will write.
#
# The defaults here still decide every case nobody has spoken about — a trigger
# with no selector, a session with no explicit class — so they remain the
# taxonomy's answer, not a fallback nobody reaches.
module SessionGenesis
  SPOT = "spot"
  PRIORITY = "priority"
  CLASSES = [ SPOT, PRIORITY ].freeze

  # Named keys, so call sites read as intent rather than as a string literal.
  WEB_UI = "web_ui"
  SLACK = "slack"
  GITHUB_ISSUE = "github_issue"
  GITHUB_LABEL = "github_label"
  SCHEDULE = "schedule"
  AO_EVENT = "ao_event"
  API = "api"
  UNKNOWN = "unknown"

  # A genesis kind, its default class, and the prose the UI and MCP both render.
  Kind = Data.define(:key, :label, :default_class, :description)

  KINDS = [
    Kind.new(
      key: WEB_UI,
      label: "Zimmer web app",
      default_class: PRIORITY,
      description: "A human typed it into the Zimmer web app — the new-session form, the " \
                   "dashboard quick prompt, the chat bubble, or the Invoke button on a trigger."
    ),
    Kind.new(
      key: SLACK,
      label: "Slack trigger",
      default_class: PRIORITY,
      description: "A Slack trigger fired on a DM or a channel message. There is a human " \
                   "on the other end waiting for an answer."
    ),
    Kind.new(
      key: GITHUB_ISSUE,
      label: "GitHub issue trigger",
      default_class: SPOT,
      description: "A github_issue trigger fired on a newly filed issue. This is the feed " \
                   "the issue-work gate reads: automated triage nobody is waiting on."
    ),
    Kind.new(
      key: GITHUB_LABEL,
      label: "GitHub label trigger",
      default_class: SPOT,
      description: "A github_label trigger fired on a label change — the `ready to merge` " \
                   "feed the PR merge gate reads. Automated, and safe to run later."
    ),
    Kind.new(
      key: SCHEDULE,
      label: "Scheduled trigger",
      default_class: SPOT,
      description: "A cron-scheduled trigger fired. Recurring automation by definition runs " \
                   "again, so a deferred run costs little."
    ),
    Kind.new(
      key: AO_EVENT,
      label: "Session-state trigger",
      default_class: SPOT,
      description: "A session-state trigger fired because another session changed state. " \
                   "Machine-to-machine follow-up with no human waiting."
    ),
    Kind.new(
      key: API,
      label: "API / agent spawn",
      default_class: SPOT,
      description: "Created over the REST API or MCP start_session with no parent session to " \
                   "inherit from, so nothing connects it to a human. An agent spawn that DOES " \
                   "carry a parent inherits that parent's genesis instead of landing here."
    ),
    Kind.new(
      key: UNKNOWN,
      label: "Unknown",
      default_class: PRIORITY,
      description: "Origin could not be established — chiefly rows created before genesis was " \
                   "recorded. Classified priority on purpose: a session Zimmer cannot explain " \
                   "is never one it throttles."
    )
  ].freeze

  KEYS = KINDS.map(&:key).freeze
  BY_KEY = KINDS.index_by(&:key).freeze
  DEFAULT_KEY = UNKNOWN

  # Trigger condition type => genesis kind. Every TriggerCondition::CONDITION_TYPES
  # value must appear here; the parity is asserted in test.
  CONDITION_TYPE_KINDS = {
    "slack" => "slack",
    "schedule" => "schedule",
    "ao_event" => "ao_event",
    "github_label" => "github_label",
    "github_issue" => "github_issue"
  }.freeze

  # Which genesis wins when one trigger carries several condition types. The
  # human-facing kinds come first, so a mixed trigger is never silently demoted
  # to spot on the strength of a condition that did not fire.
  CONDITION_TYPE_PRECEDENCE = %w[slack github_label github_issue ao_event schedule].freeze

  # The kinds a trigger can produce. Their class is chosen per trigger, so there
  # is no per-kind setting for them.
  TRIGGER_BACKED_KEYS = CONDITION_TYPE_KINDS.values.uniq.freeze

  # The kinds nothing triggers — the only ones /quotas and `action_spot_policy`
  # can still move as a whole.
  SETTABLE_KEYS = (KEYS - TRIGGER_BACKED_KEYS).freeze
  SETTABLE_KINDS = KINDS.select { |k| SETTABLE_KEYS.include?(k.key) }.freeze

  class << self
    def kind(key)
      BY_KEY[key.to_s]
    end

    # Whether this kind comes from a trigger, and so takes its class from the
    # Trigger row rather than from a per-kind setting.
    def trigger_backed?(key)
      TRIGGER_BACKED_KEYS.include?(key.to_s)
    end

    def settable?(key)
      SETTABLE_KEYS.include?(key.to_s)
    end

    def valid?(key)
      BY_KEY.key?(key.to_s)
    end

    def label(key)
      kind(key)&.label || key.to_s.presence || "Unknown"
    end

    def default_class(key)
      kind(key)&.default_class || PRIORITY
    end

    # The genesis a trigger's sessions get when the firing job does not name one.
    # `condition_types` is Trigger#condition_types.
    def from_condition_types(condition_types)
      types = Array(condition_types).map(&:to_s)
      winner = CONDITION_TYPE_PRECEDENCE.find { |t| types.include?(t) }
      CONDITION_TYPE_KINDS[winner] || DEFAULT_KEY
    end

    # The effective class of every kind, defaults merged with the persisted
    # per-kind overrides. One hash, read once, so a list view classifies N rows
    # without N lookups.
    #
    # A stored override for a trigger-backed kind is ignored rather than honored:
    # those kinds take their selector from the Trigger row, and a stray key here
    # must not quietly reclassify every trigger of that kind at once.
    def effective_classes(overrides = nil)
      overrides = AppSetting.current.genesis_class_overrides if overrides.nil?
      overrides = {} unless overrides.is_a?(Hash)

      KINDS.each_with_object({}) do |k, acc|
        override = settable?(k.key) ? overrides[k.key] : nil
        acc[k.key] = CLASSES.include?(override) ? override : k.default_class
      end
    end

    # The class one genesis resolves to right now.
    def effective_class(key, overrides = nil)
      effective_classes(overrides)[key.to_s] || PRIORITY
    end

    # Genesis keys that currently resolve to `klass`.
    def keys_classified(klass, overrides = nil)
      effective_classes(overrides).select { |_k, v| v == klass.to_s }.keys
    end

    # Whether `key`'s current class differs from the shipped default — i.e. an
    # operator has explicitly promoted or demoted it.
    def overridden?(key, overrides = nil)
      effective_class(key, overrides) != default_class(key)
    end
  end
end
