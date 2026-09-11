# frozen_string_literal: true

require "digest"

# The agent-login primitive (tadasant/zimmer#220): a short-lived, single-use, revocable
# token that an automated actor exchanges once for a web-console session cookie.
#
# Two stages, two credentials. A **standing** credential — the operator realm,
# `SUPERVISOR_PASSWORD`, the one credential the fleet's own sessions do not hold —
# mints a row and gets the plaintext token back exactly once. The **automated actor**
# (a Playwright run in CI, a post-deploy agent session) then exchanges that token, in
# a request body, for a cookie whose lifetime is `session_ttl_seconds`. What can leak
# from a job log or a transcript is a token that is dead within minutes and cannot be
# replayed, rather than the standing credential.
#
# Single-use is the point, and it is what turns a failed exchange into a signal. A
# token this actor just minted and has not used, that will not exchange, was seen by
# someone else or the flow is broken — so the actor does not retry it: it revokes the
# id, alarms, and mints afresh. A replayable token would work for the thief and the
# legitimate actor alike and produce no signal at all.
#
# The row is the whole story:
#
# - `id` is the token's `jti`. The wire form is `zlt_<id>.<secret>`; the id finds the
#   row and the secret is compared, constant-time, against `secret_digest`. Only the
#   SHA-256 digest is stored, so the table never holds anything an exchange accepts.
# - `status` is `active`, `consumed` or `revoked`. `exchange!` is one conditional
#   `UPDATE ... WHERE status = 'active'` to `consumed`, so a concurrent double-exchange
#   loses instead of succeeding twice. Expiry is not a status: an `active` row past
#   `expires_at` is dead, and the reaper deletes it once it is older than RETENTION.
# - `principal` and `role` are the authority the exchanged session carries. They are
#   copied into the cookie at exchange time and nothing about how the token is
#   presented can change them. The one role today is `console`: the web UI, and
#   nothing behind the operator realm — a console session never satisfies
#   `OperatorHttpBasicAuth`, so an actor holding one cannot mint another.
# - `session_ttl_seconds` is the cookie's `Max-Age`, decided at mint, not at exchange.
#
# Every endpoint that reads or writes this table is closed unless `CONSOLE_LOGIN_ENABLED`
# is `true`. Nothing sets it by default in any environment: the web UI has no login
# gate today, so the cookie the exchange issues authorizes nothing the perimeter does
# not already grant, and the primitive is landed so it is ready when a gate exists.
class ConsoleLoginToken < ApplicationRecord
  ENABLED_ENV = "CONSOLE_LOGIN_ENABLED"

  # Recognisably Zimmer's in a secret scanner or a pasted log, like ApiKey's `zmr_`.
  PREFIX = "zlt_"

  ACTIVE = "active"
  CONSUMED = "consumed"
  REVOKED = "revoked"
  STATUSES = [ ACTIVE, CONSUMED, REVOKED ].freeze

  CONSOLE_ROLE = "console"
  ROLES = [ CONSOLE_ROLE ].freeze

  # Mint-to-exchange window, in seconds. Short, because the token is in flight
  # through a job's environment or a transcript for exactly this long.
  DEFAULT_TTL_SECONDS = 5.minutes.to_i
  TTL_SECONDS = (10.seconds.to_i)..(15.minutes.to_i)

  # The exchanged session's lifetime, in seconds. Long enough to drive the UI through
  # a test run, short enough that a leaked cookie is not a standing credential.
  DEFAULT_SESSION_TTL_SECONDS = 15.minutes.to_i
  SESSION_TTL_SECONDS = (1.minute.to_i)..(1.hour.to_i)

  # How long a row outlives its own expiry before ConsoleLoginTokenReaperJob deletes
  # it. Consumed and revoked rows are the audit trail of who logged in and when, so
  # they are kept for a while; the WARN log lines are the durable record.
  RETENTION = 30.days

  PRINCIPAL_MAX_LENGTH = 100

  # The outcome of one presented token. `refusal` is nil on success, otherwise one of:
  #   malformed   not `zlt_<id>.<secret>`
  #   unknown     no row with that id
  #   bad_secret  a row, but the secret does not match its digest
  #   expired     the secret matched, the row was never used, and its window is over
  #   consumed    already exchanged — the tripwire
  #   revoked     revoked before it was exchanged
  # The caller decides which of these it tells the client apart; the first three are
  # deliberately one answer on the wire, so a guess at an id learns nothing.
  Exchange = Data.define(:token, :refusal) do
    def exchanged? = refusal.nil?
  end

  validates :secret_digest, presence: true
  validates :principal, presence: true, length: { maximum: PRINCIPAL_MAX_LENGTH },
    # The principal goes into log lines and the cookie: no newlines, no bidi
    # overrides, nothing that renders as something other than what it is.
    format: { without: /[\p{Cc}\p{Cf}]/, message: "can't contain control or formatting characters" }
  validates :role, inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }
  validates :expires_at, presence: true
  validates :session_ttl_seconds, numericality: { only_integer: true, in: SESSION_TTL_SECONDS }

  scope :reapable, ->(now = Time.current) { where(expires_at: ...(now - RETENTION)) }

  class << self
    # Read on every call, never memoized, like ApiKey.env_keys: a flag read once at
    # boot is a flag that cannot be turned off without a restart.
    def enabled?
      ENV[ENABLED_ENV] == "true"
    end

    # Create a token and return it with the only copy of its secret there will ever be.
    #
    # @return [Array(ConsoleLoginToken, String)]
    def mint!(principal:, ttl_seconds: DEFAULT_TTL_SECONDS, session_ttl_seconds: DEFAULT_SESSION_TTL_SECONDS, minted_from_ip: nil, now: Time.current)
      raise ArgumentError, "ttl_seconds must be in #{TTL_SECONDS}" unless TTL_SECONDS.cover?(ttl_seconds)

      secret = SecureRandom.hex(32)
      token = create!(
        secret_digest: digest(secret),
        principal: principal.to_s.strip,
        role: CONSOLE_ROLE,
        status: ACTIVE,
        expires_at: now + ttl_seconds.to_i.seconds,
        session_ttl_seconds: session_ttl_seconds,
        minted_from_ip: minted_from_ip
      )
      [ token, "#{PREFIX}#{token.id}.#{secret}" ]
    end

    # The whole exchange decision for one presented token: parse, find, compare the
    # secret, then take the row from `active` to `consumed` in one conditional UPDATE.
    #
    # The order matters. The secret is checked before any state is reported, so the
    # row-state refusals (`expired`, `consumed`, `revoked`) are only ever told to a
    # caller holding the right secret. And the UPDATE's WHERE clause is the whole
    # single-use guarantee: two requests carrying the same valid token both pass the
    # checks above it, and exactly one of them updates a row.
    #
    # @param presented [String, nil] the token off the request body
    # @return [Exchange]
    def exchange!(presented, consumed_from_ip: nil, now: Time.current)
      id, secret = parse(presented)
      return refuse(:malformed) if id.nil?

      token = find_by(id: id)
      return refuse(:unknown) if token.nil?
      return refuse(:bad_secret, token) unless token.secret_matches?(secret)

      consumed = where(id: token.id, status: ACTIVE).where("expires_at > ?", now)
        .update_all(status: CONSUMED, consumed_at: now, consumed_from_ip: consumed_from_ip, updated_at: now)

      token.reload
      return Exchange.new(token: token, refusal: nil) if consumed == 1

      refuse(token.refusal_reason(now: now), token)
    end

    def digest(secret)
      Digest::SHA256.hexdigest(secret.to_s)
    end

    private

    # `zlt_<id>.<secret>` → [id, secret], or [nil, nil] for anything else. The id is
    # decimal digits only, so a lookup never sees anything but an integer.
    def parse(presented)
      match = /\A#{PREFIX}(\d{1,18})\.([0-9a-f]{64})\z/.match(presented.to_s)
      match ? [ match[1].to_i, match[2] ] : [ nil, nil ]
    end

    def refuse(reason, token = nil)
      Exchange.new(token: token, refusal: reason)
    end
  end

  def active? = status == ACTIVE
  def consumed? = status == CONSUMED
  def revoked? = status == REVOKED

  def expired?(now: Time.current)
    expires_at <= now
  end

  # Why this row would refuse an exchange right now, or nil if it would accept one.
  # Status before expiry: a consumed row is the tripwire whether or not its window
  # has also closed, and that is the fact the actor needs.
  def refusal_reason(now: Time.current)
    return :consumed if consumed?
    return :revoked if revoked?
    return :expired if expired?(now: now)

    nil
  end

  def secret_matches?(secret)
    ActiveSupport::SecurityUtils.secure_compare(self.class.digest(secret), secret_digest)
  end

  # Idempotent, and a no-op on a consumed row: the exchanged session is its own
  # thing, with its own expiry, and revoking the token that produced it changes
  # nothing about it. One conditional UPDATE, like the exchange, so a revoke racing
  # an exchange resolves to whichever statement ran first.
  #
  # @return [Boolean] whether this call is what revoked it
  def revoke!(now: Time.current)
    changed = self.class.where(id: id, status: ACTIVE)
      .update_all(status: REVOKED, revoked_at: now, updated_at: now)
    reload
    changed == 1
  end

  # What the exchange writes into the cookie and what the whoami endpoint reports.
  # Never the digest, never the status.
  def as_console_login(now: Time.current)
    {
      token_id: id,
      principal: principal,
      role: role,
      expires_at: (now + session_ttl_seconds).iso8601
    }
  end

  # The public shape of a row: what mint and revoke return, and what a caller may
  # store. No digest.
  def as_api_json
    {
      id: id,
      principal: principal,
      role: role,
      status: status,
      expires_at: expires_at.iso8601,
      session_ttl_seconds: session_ttl_seconds,
      consumed_at: consumed_at&.iso8601,
      revoked_at: revoked_at&.iso8601,
      created_at: created_at.iso8601
    }
  end
end
