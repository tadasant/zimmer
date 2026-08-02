# frozen_string_literal: true

# One thing Zimmer *knows* a named human said, attached to the session where
# they actually said it.
#
# The defining property is provenance, not content. A HumanMessage exists only
# when the authenticated actor at an input boundary was established — the Zimmer
# web UI (a single human has browser access) or a Slack user ID that maps to a
# configured HumanIdentity. Everything else that arrives as a `user`-role turn —
# an agent's `follow_up` through the MCP/REST API, a router-composed spawn
# prompt, a scheduled or self-scheduled wake-up, a heartbeat nudge, a
# post-interruption resumption, a subagent message, a polled GitHub comment —
# is machine-authored and records NOTHING. A missing record is a correct, safe
# outcome; a wrongly-attributed one launders automation into authorization.
#
# Read-only is enforced here, not just by convention: a record cannot be updated
# or destroyed once written (except with the session it belongs to). The whole
# value of the thing is that it cannot be edited after the fact to say a human
# asked for something.
class HumanMessage < ApplicationRecord
  # How the human's words reached Zimmer. This is the provenance a reader needs
  # in order to weigh a record — `web_ui` is Tadas typing into the browser;
  # `slack` is a message resolved to a human through the Slack user ID map.
  WEB_UI = "web_ui"
  SLACK = "slack"
  CHANNELS = [ WEB_UI, SLACK ].freeze

  MAX_CONTENT_LENGTH = Session::PROMPT_MAX_LENGTH

  belongs_to :session

  validates :channel, inclusion: { in: CHANNELS }
  validates :content, presence: true, length: { maximum: MAX_CONTENT_LENGTH }
  validates :occurred_at, presence: true
  validate :author_must_be_a_known_human

  scope :chronological, -> { order(:occurred_at, :id) }

  before_update { raise ActiveRecord::ReadOnlyRecord, "HumanMessage is read-only once recorded" }
  before_destroy do
    raise ActiveRecord::ReadOnlyRecord, "HumanMessage is read-only once recorded" unless destroyed_by_association
  end

  # The identity object behind `author`, or nil if the config no longer lists
  # that name. Renderers fall back to the raw name rather than dropping the
  # record — a human said it even if the roster has since changed.
  def identity
    HumanIdentity.find(author)
  end

  def display_name
    identity&.display_name || author
  end

  # The specific boundary this came through (e.g. "web_ui.follow_up",
  # "slack.channel_message"), so two records on the same channel are still
  # distinguishable.
  def entry_point
    provenance["entry_point"]
  end

  def slack_permalink
    provenance["slack_permalink"]
  end

  def slack_channel_name
    provenance["slack_channel"]
  end

  # Where this message reached Zimmer, in words a reader can weigh.
  def channel_label
    case channel
    when WEB_UI then "Zimmer web UI"
    when SLACK
      slack_channel_name.present? ? "Slack (#{slack_channel_name})" : "Slack"
    else channel
    end
  end

  private

  def author_must_be_a_known_human
    return if author.present? && HumanIdentity.find(author).present?

    errors.add(:author, "must be a configured human identity")
  end
end
