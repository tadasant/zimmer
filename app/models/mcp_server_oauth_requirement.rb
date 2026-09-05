# What a remote MCP server said, the last time Zimmer asked it, about whether it
# requires OAuth.
#
# Zimmer already asks — the spawn gate (`AgentSessionJob#check_and_inject_oauth_credentials`)
# and the session-page probe (`McpOauthProbe`) both run RFC 9728 / RFC 8414
# discovery and an unauthenticated request against the server URL. Both then threw
# the answer away, so every other surface fell back to a guess: a remote server
# with no static credential header and no stored token *might* need OAuth, so
# assume it does. That guess is one of three distinct causes behind a single
# user-visible symptom — "the agent says it needs to authorize this server" — and
# it is the one that produces the symptom for servers that never needed OAuth at
# all.
#
# This is where the answer is kept, so it is a recorded fact rather than a guess
# re-made per injection.
#
# ## Keyed on the server config, not the server name
#
# `credential_key` is `McpOauthCredential.compute_credential_key(name, config)` —
# a digest of `{type, url, headers}`. Keying on it means a catalog edit that
# changes the URL or headers invalidates the determination exactly as it
# invalidates the stored credential: the new config is a different server as far
# as authorization is concerned, and it gets asked again.
#
# ## The three determinations
#
# - `advertised_required` — the server advertised OAuth: discovery resolved an
#   authorization server, or an unauthenticated request came back `401` with a
#   `Bearer` challenge.
# - `advertised_not_required` — an unauthenticated request *succeeded* (2xx). The
#   server served us without a token, which is the only positive evidence that no
#   token is needed.
# - `undetermined` — we asked and could not tell: a connection error, a timeout, a
#   `401` with a non-Bearer challenge, or any other status. Not an answer, and
#   never treated as one.
#
# ## Erring strict is the dangerous direction
#
# Deciding "this server does not need OAuth" and being wrong is a worse failure
# than today's over-eager guess, because it is silent: the server never gets
# credentials and fails at the point of use. Two rules keep that narrow.
#
# 1. Only a 2xx records `advertised_not_required`. Every other non-401 status —
#   `400`, `404`, `405`, `5xx` — is `undetermined`. An MCP server that answers a
#   bare `GET` with `400 missing session id` before it ever checks a token has
#   told us nothing about authorization.
# 2. `advertised_not_required` expires. Past {NOT_REQUIRED_TTL} the record stops
#   answering "no" and degrades to undetermined, so a server that starts
#   requiring OAuth cannot be permanently believed not to. `advertised_required`
#   does not expire — the failure it causes is a visible Authorize button, not a
#   silent one.
#
# Anything the record cannot settle falls back to the old assumption, unchanged:
# unknown means "assume it might be required".
class McpServerOauthRequirement < ApplicationRecord
  # The server told us it requires OAuth.
  ADVERTISED_REQUIRED = "advertised_required"
  # The server served an unauthenticated request, so it told us it does not.
  ADVERTISED_NOT_REQUIRED = "advertised_not_required"
  # We asked and could not tell. Callers assume OAuth might be required.
  UNDETERMINED = "undetermined"

  DETERMINATIONS = [ ADVERTISED_REQUIRED, ADVERTISED_NOT_REQUIRED, UNDETERMINED ].freeze

  # How long an `advertised_not_required` answer is believed. See the class
  # comment: this is the one direction whose failure is silent, so it is the one
  # with a shelf life. Every probe rewrites the record, and probes run on every
  # spawn gate and every catalog-selection change for a server with no valid
  # credential, so in practice a live server's answer is far fresher than this.
  NOT_REQUIRED_TTL = 7.days

  validates :server_name, presence: true
  validates :credential_key, presence: true, uniqueness: true
  validates :determination, presence: true, inclusion: { in: DETERMINATIONS }
  validates :determined_at, presence: true

  scope :for_credential_key, ->(key) { where(credential_key: key) }

  # Records what a probe just learned, replacing whatever was recorded for this
  # server config before. The freshest observation wins: a server that starts (or
  # stops) requiring OAuth is re-answered by the next probe rather than
  # accumulating history nobody reads.
  #
  # Best-effort by contract. Recording a determination is bookkeeping alongside a
  # probe whose answer the caller already has; a write that fails must never turn
  # a working spawn into a failed one.
  #
  # @param server_name [String]
  # @param credential_key [String] see {McpOauthCredential.compute_credential_key}
  # @param determination [String] one of {DETERMINATIONS}
  # @param server_url [String, nil]
  # @param detail [String, nil] why, in a few words — an HTTP status or an error
  # @return [McpServerOauthRequirement, nil] nil if the write failed
  def self.record!(server_name:, credential_key:, determination:, server_url: nil, detail: nil)
    return nil if server_name.blank? || credential_key.blank?
    return nil unless DETERMINATIONS.include?(determination)

    # One statement, so two sessions probing the same server config at the same
    # moment cannot race: a read-then-write would have both miss the row, both
    # insert, and one lose the unique index. They are writing the same kind of
    # fact about the same server, so last write wins is the intended outcome and
    # the conflict is not worth surfacing. The manual guards above stand in for
    # the validations `upsert` skips; the NOT NULLs are on the columns.
    upsert(
      {
        credential_key: credential_key,
        server_name: server_name,
        server_url: server_url,
        determination: determination,
        detail: detail.to_s.presence&.truncate(255),
        determined_at: Time.current
      },
      unique_by: :credential_key,
      record_timestamps: true
    )

    for_credential_key(credential_key).first
  rescue StandardError => e
    Rails.logger.warn "[McpServerOauthRequirement] Failed to record #{determination} for #{server_name}: #{e.message}"
    nil
  end

  # The determination in force for a server config, as a string, always. No
  # record — or one that has gone stale — reads as {UNDETERMINED}, so callers
  # never have to spell the fallback themselves.
  #
  # @param credential_key [String]
  # @return [String] one of {DETERMINATIONS}
  def self.determination_for(credential_key)
    return UNDETERMINED if credential_key.blank?

    for_credential_key(credential_key).first&.effective_determination || UNDETERMINED
  end

  # True / false when the server answered, nil when it did not. The nil is the
  # point: it is what makes "we could not determine it" distinguishable from
  # "it said no", and callers turn it into the old assumption themselves.
  #
  # @param credential_key [String]
  # @return [Boolean, nil]
  def self.oauth_required_for(credential_key)
    case determination_for(credential_key)
    when ADVERTISED_REQUIRED then true
    when ADVERTISED_NOT_REQUIRED then false
    end
  end

  # The determination this record still supports today — its own, unless it is a
  # `advertised_not_required` that has outlived {NOT_REQUIRED_TTL}.
  #
  # @return [String]
  def effective_determination
    return UNDETERMINED if stale?

    determination
  end

  # @return [Boolean] true for a `advertised_not_required` past its TTL
  def stale?
    return false unless determination == ADVERTISED_NOT_REQUIRED
    return true if determined_at.nil?

    determined_at < NOT_REQUIRED_TTL.ago
  end

  # One line for a human triaging "why does it say I need to authorize this?".
  #
  # @return [String]
  def description
    case effective_determination
    when ADVERTISED_REQUIRED then "the server advertises that it requires OAuth"
    when ADVERTISED_NOT_REQUIRED then "the server served an unauthenticated request, so it advertises no OAuth requirement"
    else "Zimmer could not determine whether this server requires OAuth, so it assumes it might"
    end
  end
end
