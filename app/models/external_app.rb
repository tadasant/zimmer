# frozen_string_literal: true

# A Zimmer plugin: an app outside Zimmer that may invoke a fixed set of triggers
# and do nothing else.
#
# The first one is a housing-search MCP app with a "Kick off vetting" button:
# pressing it invokes the vetting trigger with the listing in `{{text}}`. The app
# (or the gateway in front of it) holds the credential, and that credential sits
# outside this deployment's circle of trust, so what it can do is decided here, on
# the server, not by the URL it is configured with:
#
# - **Its keys are ApiKey rows with the `external_app` grant.** ApiKey.authenticate
#   matches a grant exactly, and every REST controller and `/mcp` ask for `api`, so
#   a plugin key is refused by the whole existing API without any of it knowing
#   plugins exist. Two surfaces ask for `external_app` and nothing else:
#   `POST /mcp/external_app` and `/api/v1/external_app/...`.
# - **Those surfaces reach only the triggers on the allowlist** (`triggers`,
#   through `external_app_triggers`) and only while the app is `enabled`. A trigger
#   that is not on the list answers exactly as one that does not exist does.
#
# Invoking goes through ExternalApps::InvokeTrigger, which fires the trigger the way
# the Invoke button does (Triggers::ManualFire) and stamps the session it creates
# with `external_app_id` / `external_app_name` in its metadata.
#
# Named "external app" in code so it cannot be mistaken for an AIR catalog plugin
# (`plugins/`, a session's `catalog_plugins`), which is a different thing entirely.
# The UI and the docs call it a Zimmer plugin.
class ExternalApp < ApplicationRecord
  # The metadata keys a session this app fired carries.
  SESSION_METADATA_ID_KEY = "external_app_id"
  SESSION_METADATA_NAME_KEY = "external_app_name"

  # `last_invoked_at` is written at most once per app per this interval, like
  # ApiKey#record_use!: a batch of thirty invokes is one write, not thirty.
  LAST_INVOKED_RESOLUTION = 1.minute

  has_many :external_app_triggers, dependent: :delete_all
  has_many :triggers, through: :external_app_triggers
  # The FK cascades too; `dependent` makes a Rails-side destroy say so explicitly.
  has_many :api_keys, dependent: :delete_all

  validates :name, presence: true, length: { maximum: 100 },
    uniqueness: { case_sensitive: false },
    # The name goes into log lines, session metadata and confirm dialogs.
    format: { without: /[\p{Cc}\p{Cf}]/, message: "can't contain control or formatting characters" }
  validates :description, length: { maximum: 2000 }

  scope :listed, -> { order(Arel.sql("lower(name)")) }

  # The triggers an admin may put on an allowlist: every trigger that fires from a
  # prompt template. A workflow trigger has no template to fill, so invoking it with
  # variables means nothing — and Triggers::ManualFire cannot fire one.
  def self.allowlistable_triggers
    Trigger.where(workflow_id: nil).order(Arel.sql("lower(name)"))
  end

  # A new key for this app, and the only copy of its secret there will ever be.
  #
  # The key is named after the app plus a timestamp, so the API keys page and the
  # request log say whose it is; `ApiKey` names are unique, so two mints in the same
  # second get a suffix.
  #
  # @return [Array(ApiKey, String)]
  def mint_key!(label: nil)
    base = "Zimmer plugin #{name}: #{label.presence || Time.current.utc.strftime('%Y-%m-%d %H:%M:%S UTC')}"
    candidates = [ base ] + (2..5).map { |n| "#{base} (#{n})" }
    candidates.each do |candidate|
      return ApiKey.mint!(name: candidate.truncate(100, omission: ""), grant: ApiKey::EXTERNAL_APP_GRANT, external_app: self)
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.errors.of_kind?(:name, :taken)
    end
    raise ActiveRecord::RecordNotSaved, "no free key name for #{name.inspect}"
  end

  def active_keys
    api_keys.select { |key| !key.revoked? }
  end

  # Refused allowlist edits: an id that names no trigger, or a workflow trigger.
  class InvalidAllowlist < StandardError; end

  # Replace the allowlist with exactly these trigger ids. Anything that does not
  # name an allowlistable trigger raises before a row is touched, so a typo is an
  # error rather than a silently shorter list. On a persisted app the new list is
  # written immediately, in one transaction.
  def replace_triggers!(ids)
    ids = Array(ids).map { |id| id.to_s.strip }.reject(&:empty?).uniq
    numeric = ids.select { |id| id.match?(/\A\d+\z/) }.map(&:to_i)
    found = Trigger.where(id: numeric).to_a
    missing = ids - found.map { |trigger| trigger.id.to_s }
    raise InvalidAllowlist, "No trigger with id #{missing.join(', ')}" if missing.any?

    workflow = found.select(&:workflow_backed?)
    if workflow.any?
      raise InvalidAllowlist, "#{workflow.map { |t| "\"#{t.name}\" (#{t.id})" }.join(', ')} runs a workflow — " \
                              "a plugin fills a prompt template, and a workflow trigger has none"
    end

    transaction { self.triggers = found }
  end

  # Whether this app may invoke `trigger` right now.
  def may_invoke?(trigger)
    enabled? && trigger.present? && external_app_triggers.exists?(trigger_id: trigger.id)
  end

  # Stamp `last_invoked_at`, at most once per LAST_INVOKED_RESOLUTION. One
  # conditional UPDATE; a failure is logged and swallowed, because bookkeeping must
  # not fail the invoke it describes.
  def record_invocation!(now: Time.current)
    return if last_invoked_at && last_invoked_at > now - LAST_INVOKED_RESOLUTION

    stamped = self.class.where(id: id)
      .where("last_invoked_at IS NULL OR last_invoked_at <= ?", now - LAST_INVOKED_RESOLUTION)
      .update_all(last_invoked_at: now)
    self.last_invoked_at = now if stamped.positive?
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[external_app] could not stamp last_invoked_at on #{name.inspect} (id=#{id}): #{e.class}: #{e.message.truncate(200)}")
  end

  # What a session this app fired records about it.
  def session_metadata
    { SESSION_METADATA_ID_KEY => id, SESSION_METADATA_NAME_KEY => name }
  end

  # Sessions this app has fired, newest first.
  def sessions
    Session.where("metadata->>? = ?", SESSION_METADATA_ID_KEY, id.to_s).order(created_at: :desc)
  end
end
