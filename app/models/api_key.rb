# frozen_string_literal: true

require "digest"

# A credential for the REST API and the native MCP endpoint (tadasant/zimmer#46).
#
# Zimmer is a single circle of trust, so a key still grants the whole API — there
# are no scopes. What a row adds is identity: a **name** the request log can print,
# a **`last_used_at`** that says whether anything still holds it, and a
# **`revoked_at`** that turns it off on the very next request, no restart.
#
# Keys come from two places, recorded in `source`:
#
# - **`env`** — an entry in `ENV["API_KEYS"]`. Every client that exists today holds
#   one of these, including every agent session (the self-session MCP server is
#   handed the first entry), so they keep working exactly as before. The first
#   time an entry authenticates it gets a row, named after its fingerprint, and
#   from then on it can be named in the logs and revoked like any other key. An
#   `env` row authenticates only while its key is still in `API_KEYS`: taking a
#   key out of the variable and redeploying retires it, the way it always did.
# - **`minted`** — created on the API keys settings page. The key exists only in
#   the response that created it; this table holds its SHA-256 digest.
#
# **No key is ever stored or logged.** A row holds the digest, and the one thing
# derived from it that is ever displayed is an 8-character fingerprint of that
# digest — enough to tell keys apart, and the same prefix
# `printf %s "$KEY" | sha256sum` prints, so an operator can match a key they hold
# to its row.
#
# Nothing here is cached beyond the row itself: every request re-reads
# `API_KEYS` and re-finds the row, which is what makes a revoke take effect
# immediately in every Puma worker.
class ApiKey < ApplicationRecord
  ENV_VAR = "API_KEYS"

  ENV_SOURCE = "env"
  MINTED_SOURCE = "minted"
  SOURCES = [ ENV_SOURCE, MINTED_SOURCE ].freeze

  # Names beginning with this are the ones `env` rows are registered under, so an
  # operator cannot mint a key that reads like one of them in a log line.
  ENV_NAME_PREFIX = "API_KEYS "

  # Minted keys are recognisably Zimmer's in a secret scanner or a pasted log.
  MINTED_PREFIX = "zmr_"

  FINGERPRINT_LENGTH = 8

  # `last_used_at` is written at most once per key per this interval. A busy
  # session calls /mcp several times a minute, and a write per call would be
  # write amplification for a field whose question is "days or minutes?".
  LAST_USED_RESOLUTION = 1.minute

  # Why a request was refused, for the log line — never shown to the caller, who
  # gets the same 401 for all of them.
  #   missing  no key on the request
  #   unknown  a key no row and no API_KEYS entry matches
  #   revoked  a row that has been revoked
  #   retired  an `env` row whose key is no longer in API_KEYS
  Authentication = Data.define(:api_key, :refusal) do
    def authenticated? = refusal.nil?
  end

  validates :name, presence: true, length: { maximum: 100 },
    uniqueness: { case_sensitive: false },
    # The name goes into log lines and a confirm dialog: no newlines, no bidi
    # overrides, nothing that renders as something other than what it is.
    format: { without: /[\p{Cc}\p{Cf}]/, message: "can't contain control or formatting characters" }
  validates :token_digest, presence: true, uniqueness: true
  validates :source, inclusion: { in: SOURCES }
  validate :name_not_reserved, if: :minted?

  scope :listed, -> { order(Arel.sql("revoked_at IS NOT NULL"), created_at: :desc) }

  class << self
    # The whole authentication decision for one presented key.
    #
    # @param presented [String, nil] the key off the request
    # @return [Authentication]
    def authenticate(presented)
      return refuse(:missing) if presented.blank?

      in_env = env_keys.any? { |key| ActiveSupport::SecurityUtils.secure_compare(key, presented) }
      digest = digest(presented)

      api_key = find_by(token_digest: digest)
      api_key ||= register_env_key(digest) if in_env

      return refuse(:unknown) if api_key.nil?
      return refuse(:revoked, api_key) if api_key.revoked?
      return refuse(:retired, api_key) if api_key.env? && !in_env

      api_key.record_use!
      Authentication.new(api_key: api_key, refusal: nil)
    end

    # Create a key and return it with the only copy of its secret there will ever be.
    #
    # @return [Array(ApiKey, String)]
    def mint!(name:)
      token = "#{MINTED_PREFIX}#{SecureRandom.hex(32)}"
      api_key = create!(name: name.to_s.strip, source: MINTED_SOURCE, token_digest: digest(token))
      [ api_key, token ]
    end

    # Give every `API_KEYS` entry a row, so the settings page lists keys that have
    # not authenticated since this table existed. Idempotent; the auth path does the
    # same thing lazily, one key at a time.
    def register_env_keys
      env_keys.each do |key|
        digest = digest(key)
        register_env_key(digest) unless exists?(token_digest: digest)
      end
    end

    # Read on every call, never memoized: a process-lifetime copy is how a key
    # outlives its removal.
    def env_keys
      ENV.fetch(ENV_VAR, "").split(",").map(&:strip).reject(&:empty?)
    end

    def digest(key)
      Digest::SHA256.hexdigest(key.to_s)
    end

    private

    def refuse(reason, api_key = nil)
      Authentication.new(api_key: api_key, refusal: reason)
    end

    # The row for an `API_KEYS` entry that has none yet.
    #
    # This must never be the reason a key that authenticated yesterday is refused
    # today. Several workers registering one key at once is the normal case on the
    # first deploy — every session calls /mcp — and the loser's `create!` fails its
    # uniqueness validation or the unique index, so it re-reads the winner's row. A
    # name some other row already holds (only another entry sharing the 8-character
    # fingerprint can) gets the full digest instead. Anything else authenticates the
    # key as an unsaved row with the same name, which is exactly what `API_KEYS` did
    # before this table existed.
    def register_env_key(digest)
      name = "#{ENV_NAME_PREFIX}#{digest[0, FINGERPRINT_LENGTH]}"
      [ name, "#{ENV_NAME_PREFIX}#{digest}" ].each do |candidate|
        return transaction(requires_new: true) { create!(name: candidate, source: ENV_SOURCE, token_digest: digest) }
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        existing = find_by(token_digest: digest)
        return existing if existing
      end
      raise ActiveRecord::RecordNotSaved, "no free name for API_KEYS entry #{name}"
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn(
        "[api_key] could not record a row for API_KEYS entry #{name}; authenticating it without one: " \
        "#{e.class}: #{e.message.truncate(200)}"
      )
      new(name: name, source: ENV_SOURCE, token_digest: digest)
    end
  end

  def env? = source == ENV_SOURCE
  def minted? = source == MINTED_SOURCE
  def revoked? = revoked_at.present?

  # The first characters of the key's SHA-256 — what the settings page shows.
  def fingerprint
    token_digest.to_s[0, FINGERPRINT_LENGTH]
  end

  # An `env` row whose key has been taken out of `API_KEYS`. It authenticates
  # nothing, and stays listed so the logs' name for it still resolves.
  def retired?
    env? && self.class.env_keys.none? { |key| ActiveSupport::SecurityUtils.secure_compare(self.class.digest(key), token_digest) }
  end

  # The key this deployment hands its own agent sessions for their Zimmer MCP
  # servers. Revoking it disconnects every session from Zimmer at once, so the
  # settings page says so before it lets anyone try.
  def self_session_key?(self_session_digest)
    self_session_digest.present? && ActiveSupport::SecurityUtils.secure_compare(self_session_digest, token_digest)
  end

  def revoke!
    update!(revoked_at: Time.current) unless revoked?
  end

  def restore!
    update!(revoked_at: nil) if revoked?
  end

  # Stamp `last_used_at`, at most once per LAST_USED_RESOLUTION.
  #
  # One conditional UPDATE, so concurrent requests on one key never queue on a row
  # lock and `updated_at` keeps meaning "an operator changed this row". A failure
  # is logged and swallowed: bookkeeping must not fail the request it describes.
  def record_use!(now: Time.current)
    return if new_record?
    return if last_used_at && last_used_at > now - LAST_USED_RESOLUTION

    stamped = self.class.where(id: id)
      .where("last_used_at IS NULL OR last_used_at <= ?", now - LAST_USED_RESOLUTION)
      .update_all(last_used_at: now)
    self.last_used_at = now if stamped.positive?
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[api_key] could not stamp last_used_at on #{name.inspect} (id=#{id}): #{e.class}: #{e.message.truncate(200)}")
  end

  private

  # Case-insensitive, like the unique index on `lower(name)`.
  def name_not_reserved
    return unless name.to_s.downcase.start_with?(ENV_NAME_PREFIX.strip.downcase)

    errors.add(:name, "can't start with \"#{ENV_NAME_PREFIX.strip}\" — that prefix names keys registered from the API_KEYS variable")
  end
end
