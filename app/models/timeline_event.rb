# frozen_string_literal: true

# One entry in a session's Timeline: an append-only, ordered record of things
# Zimmer *knows* a named human said.
#
# The defining property is provenance, not content. A TimelineEvent exists only
# when the authenticated actor at an input boundary was established — the Zimmer
# web UI (a single human has browser access) or a Slack user ID that maps to a
# configured HumanIdentity. Everything else that arrives as a `user`-role turn —
# an agent's `follow_up` through the MCP/REST API, a router-composed downstream
# prompt, a scheduled or self-scheduled wake-up, a heartbeat nudge, a
# post-interruption resumption, a subagent message, a polled GitHub comment —
# is machine-authored and records NOTHING. A missing event is a correct, safe
# outcome; a wrongly-attributed one launders automation into authorization.
#
# Append-only is enforced here, not just by convention: an event cannot be
# updated or destroyed once written (except via the session's own dependent
# destroy). The whole value of the record is that it cannot be edited after the
# fact to say a human asked for something.
class TimelineEvent < ApplicationRecord
  # The only event type today. The column exists so a second kind of event can
  # be added without a migration, and so every reader must state which kind it
  # is asking for rather than assuming the table is homogeneous.
  HUMAN_MESSAGE = "human_message"
  EVENT_TYPES = [ HUMAN_MESSAGE ].freeze

  # How the human's words reached Zimmer. This is the provenance the reader
  # needs in order to decide how much weight an event carries — `web_ui` is
  # Tadas typing into the browser; `slack` is a message resolved to a human
  # through the Slack user ID map.
  WEB_UI = "web_ui"
  SLACK = "slack"
  CHANNELS = [ WEB_UI, SLACK ].freeze

  MAX_CONTENT_LENGTH = Session::PROMPT_MAX_LENGTH

  belongs_to :session

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :channel, inclusion: { in: CHANNELS }
  validates :content, presence: true, length: { maximum: MAX_CONTENT_LENGTH }
  validates :occurred_at, presence: true
  validate :author_must_be_a_known_human

  scope :chronological, -> { order(:occurred_at, :id) }
  scope :human_messages, -> { where(event_type: HUMAN_MESSAGE) }

  before_update { raise ActiveRecord::ReadOnlyRecord, "TimelineEvent is append-only" }
  before_destroy do
    raise ActiveRecord::ReadOnlyRecord, "TimelineEvent is append-only" unless destroyed_by_association
  end

  # The identity object behind `author`, or nil if the config no longer lists
  # that name. Renderers fall back to the raw name rather than dropping the
  # event — a human said it even if the roster has since changed.
  def identity
    HumanIdentity.find(author)
  end

  def display_name
    identity&.display_name || author
  end

  # Where this event happened, in words, for a reader who is deciding whether it
  # authorizes anything. `entry_point` records the specific boundary
  # (e.g. "web_ui.follow_up", "slack.trigger_message") so two events on the same
  # channel are still distinguishable.
  def entry_point
    provenance["entry_point"]
  end

  def slack_permalink
    provenance["slack_permalink"]
  end

  def slack_channel_name
    provenance["slack_channel"]
  end

  private

  def author_must_be_a_known_human
    return if author.present? && HumanIdentity.find(author).present?

    errors.add(:author, "must be a configured human identity")
  end
end
