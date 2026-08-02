# frozen_string_literal: true

# A named human being this Zimmer deployment knows about.
#
# This is a hand-seeded roster, NOT authentication. Zimmer has no signup and no
# login: rows exist so that when Zimmer establishes who spoke at an input
# boundary, it has something durable to attribute the words to — and somewhere
# to hang per-person context that policy decisions can read.
#
# Two ideas that used to live in two places (a YAML file and an env var) now
# live in one row:
#
#   * WHO the humans are — `key`, `display_name`, `email`, `notes`.
#   * WHICH external account belongs to which human — `slack_user_ids`.
#
# Slack IDs are deployment configuration, and this repository is public, so the
# seeded rows ship with an EMPTY array and a deployment fills them in at
# /supervisor/users. Until it does, no Slack message is attributed to anybody —
# which is why the roster is a table and not a file: switching attribution on is
# a row edit, not a deploy.
#
# `key` is load-bearing. HumanMessage#author has stored it as a plain string
# since the first records were written, and those records are immutable by
# design — renaming a key orphans them (the message still renders, falling back
# to the raw key, but it stops resolving to a person).
class User < ApplicationRecord
  # Names the human responsible for anything typed into the Zimmer web UI.
  # Deployment configuration, resolved through SecretsLoader first and process
  # ENV second — the same order TriggerCondition.default_allowed_user_ids uses.
  ADMIN_ENV_KEY = "ZIMMER_ADMIN_USER"

  # Who the admin is when the deployment says nothing. Hardcoded for now, which
  # is what the single circle of trust actually looks like: one human reaches
  # the browser. Note this is a KEY, not a guess — it resolves through the same
  # lookup as the env var, so if no such row exists the answer is still nil.
  DEFAULT_ADMIN_KEY = "tadasant"

  KEY_FORMAT = /\A[a-z0-9][a-z0-9_.-]*\z/

  # The roster as shipped, for `db:seed` on a fresh install. The migration that
  # creates the table inserts the same two rows in raw SQL — deliberately
  # duplicated, because a migration replayed years from now must not depend on
  # what this file says then. `slack_user_ids` is absent from both: it is
  # deployment configuration and this repository is public.
  SEEDED = [
    {
      key: "tadasant",
      display_name: "Tadas",
      email: "tadas@tadasant.com",
      notes: "Owns and operates this Zimmer deployment, and is its admin: " \
             "anything typed into the Zimmer web UI is his. When his instruction " \
             "conflicts with an inference you drew, his instruction wins."
    },
    {
      key: "juliehazz",
      display_name: "Julie",
      email: "julie@tadasant.com",
      notes: "The other named human in this deployment's circle of trust. Her " \
             "messages are genuine human instruction, but she is not the admin: " \
             "web UI actions are not attributed to her."
    }
  ].freeze

  has_many :human_messages, primary_key: :key, foreign_key: :author,
           inverse_of: :user, dependent: nil

  validates :key, presence: true, uniqueness: { case_sensitive: false },
            format: { with: KEY_FORMAT, message: "must be lowercase letters, digits, dashes, dots or underscores" }
  validates :display_name, presence: true
  validates :email, uniqueness: { case_sensitive: false }, allow_blank: true
  validate :email_must_look_like_an_address
  validate :slack_user_ids_must_be_distinct_across_users

  normalizes :email, with: ->(value) { value.to_s.strip.downcase.presence }
  normalizes :slack_user_ids, with: ->(ids) { Array(ids).map { |id| id.to_s.strip }.reject(&:blank?).uniq }

  scope :alphabetical, -> { order(:key) }

  class << self
    # The human behind a stable identity key, or nil when nobody holds it.
    def for_key(key)
      return nil if key.blank?

      find_by(key: key.to_s)
    end

    # The human responsible for web UI actions.
    #
    # Returns nil rather than guessing when the configured key names nobody:
    # web-UI capture then records nothing, which is the safe direction. A
    # missing record is safe; a wrongly-attributed one launders automation into
    # authorization.
    def admin
      for_key(admin_key)
    end

    # The human behind a Slack user ID, or nil when the ID maps to nobody we
    # know. nil is a correct answer: an unmapped Slack account may be another
    # workspace member, a bot, or an app posting with a bot token.
    def for_slack_user_id(slack_user_id)
      return nil if slack_user_id.blank?

      where("slack_user_ids @> ARRAY[?]::varchar[]", slack_user_id.to_s).first
    end

    # The human at an email address. Not yet wired to a capture boundary — see
    # the note in HumanMessageCapture about `auth_identity_email`.
    def for_email(email)
      return nil if email.blank?

      find_by("LOWER(email) = ?", email.to_s.strip.downcase)
    end

    def admin_key
      configured = SecretsLoader.get(ADMIN_ENV_KEY) || ENV[ADMIN_ENV_KEY]
      configured.presence&.strip || DEFAULT_ADMIN_KEY
    end
  end

  def admin? = key == self.class.admin_key

  # Comma-separated view of `slack_user_ids`, for the Supervisor form — a
  # Postgres array has no native Administrate field.
  def slack_user_ids_list = slack_user_ids.join(", ")

  def slack_user_ids_list=(value)
    self.slack_user_ids = value.to_s.split(",")
  end

  def to_s = key

  private

  def email_must_look_like_an_address
    return if email.blank?
    return if email.match?(URI::MailTo::EMAIL_REGEXP)

    errors.add(:email, "must be a valid email address")
  end

  # A Slack ID that resolved to two humans would make the author of a message
  # depend on row order. Reject the collision instead.
  def slack_user_ids_must_be_distinct_across_users
    ids = Array(slack_user_ids)
    return if ids.empty?

    clash = self.class.where.not(id: id).where("slack_user_ids && ARRAY[?]::varchar[]", ids).first
    return if clash.nil?

    errors.add(:slack_user_ids, "already belong to #{clash.key}")
  end
end
