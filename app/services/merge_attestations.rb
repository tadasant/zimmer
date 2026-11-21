# frozen_string_literal: true

# Signed human merge approvals between two Zimmer deployments.
#
# == The problem
#
# A Zimmer session can drive a session on another Zimmer deployment through
# that deployment's MCP server. When the remote session opens a pull request
# and the remote merge gate holds it for a human, the human who can release it
# may be talking to THIS Zimmer (Live Mode, on a phone or in a car), not the
# remote one. The remote side cannot tell a real yes from an agent's text: any
# agent can type "the human approved this" into a follow-up.
#
# == The answer
#
# This Zimmer, which can tell (HumanMessageCapture), signs a short-lived,
# single-use approval for exactly one pull request at exactly one commit, and
# the remote Zimmer verifies the signature against keys it was configured to
# trust before treating it as a human sign-off. The token is a compact JWS
# (RFC 7515) with an Ed25519 signature (`alg: EdDSA`, RFC 8037).
#
# * Minting is LiveConversations::AuthorizeMerge's confirm step and nothing
#   else: the same one-question, fresh, signed-in yes the voice Merge button
#   already requires. No MCP tool, REST endpoint or job mints. The signing key
#   lives in the Rails process's environment, which no agent session reads.
# * The token names repo, PR number and head SHA, so a push voids it; expires
#   within MAX_LIFETIME; and carries a `jti` the receiver claims with a unique
#   insert, so it merges once.
# * Both sides keep a MergeAttestation row, and both write a HumanMessage: the
#   issuer the person's `live_mode` yes, the receiver an `attested` record.
#
# The full contract — payload, key distribution, verification steps, failure
# modes — is docs/src/content/docs/auth/merge-attestations.md.
module MergeAttestations
  ALG = "EdDSA"
  TYP = "zimmer-merge-approval+jwt"
  VERSION = 1

  # How long a signed approval is good for. It is delivered by the request
  # that minted it, within seconds, so this only bounds how long a token that
  # leaked in transit stays worth anything.
  LIFETIME = 5.minutes
  # The longest lifetime a receiver accepts, whatever the issuer wrote.
  MAX_LIFETIME = 10.minutes
  # Clock skew a receiver tolerates on `iat` and `exp`.
  CLOCK_SKEW = 30.seconds
  # A token past this is not one Zimmer wrote.
  MAX_TOKEN_BYTES = 16.kilobytes

  # The only channel that mints today: Live Mode's authorize_merge.
  CHANNELS = %w[live_mode].freeze

  PR_URL = %r{\Ahttps://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\d+)\z}
  SHA = /\A[0-9a-f]{40}\z/

  # The MCP tools a receiving Zimmer serves (group `merge_attestations`).
  TARGET_TOOL = "get_merge_attestation_target"
  SUBMIT_TOOL = "submit_merge_attestation"

  # A token or a claim that does not verify. `code` is a stable, machine-readable
  # reason; the message is for a person.
  class Rejected < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  # The env vars, all read at call time so a test (or a re-deploy) can change
  # them without a restart.
  SIGNING_KEY_ENV = "MERGE_ATTESTATION_SIGNING_KEY"
  ISSUER_ENV = "MERGE_ATTESTATION_ISSUER"
  REMOTE_SERVERS_ENV = "MERGE_ATTESTATION_REMOTE_SERVERS"
  AUDIENCE_ENV = "MERGE_ATTESTATION_AUDIENCE"
  TRUSTED_ISSUERS_ENV = "MERGE_ATTESTATION_TRUSTED_ISSUERS"

  module_function

  # This Zimmer's name as an issuer (`iss`).
  def issuer = ENV[ISSUER_ENV].presence || AppUrl.base_url

  # This Zimmer's name as a receiver (`aud`).
  def audience = ENV[AUDIENCE_ENV].presence || AppUrl.base_url

  # The catalog MCP servers that are other Zimmer deployments this one may
  # send signed approvals to, each with the audience (`aud`) that deployment
  # must answer to: comma-separated `server=audience` pairs, for example
  # `remote-zimmer=https://remote.example.com`. The audience is pinned here
  # rather than taken from the remote's answer, so a remote cannot obtain a
  # token addressed to another deployment. An entry without one is ignored.
  #
  # @return [Hash{String => String}]
  def remote_servers
    ENV[REMOTE_SERVERS_ENV].to_s.split(",").each_with_object({}) do |pair, remotes|
      name, audience = pair.split("=", 2).map { |part| part.to_s.strip }
      remotes[name] = audience if name.present? && audience.present?
    end
  end

  # "owner/repo" and the number, or nil when it is not a PR URL.
  def parse_pr_url(url)
    match = PR_URL.match(url.to_s)
    match && [ "#{match[1]}/#{match[2]}", match[3].to_i ]
  end
end
