# frozen_string_literal: true

module OauthServer
  # An access or refresh token. Only the digest is stored. A token is good while
  # it is unexpired and its grant is unrevoked; a refresh token is also spent by
  # the exchange that rotates it (`rotated_at`).
  #
  # A pair issued by a refresh names the refresh token it was traded for
  # (`rotated_from_id`), and a pair records when it first reached its client
  # (`used_at`), so a spent refresh token presented again can be told apart:
  # its client either never received the pair (unused) or is not its client.
  class Token < ApplicationRecord
    ACCESS = "access"
    REFRESH = "refresh"
    KINDS = [ ACCESS, REFRESH ].freeze

    belongs_to :grant, class_name: "OauthServer::Grant", foreign_key: :oauth_server_grant_id,
      inverse_of: :tokens

    validates :kind, inclusion: { in: KINDS }

    # Why a presented token was refused, for the log — the caller gets the same
    # answer for all of them.
    Lookup = Data.define(:token, :refusal) do
      def ok? = refusal.nil?
      def grant = token&.grant
    end

    class << self
      # @return [Lookup]
      def lookup(presented, kind:)
        return Lookup.new(token: nil, refusal: :missing) if presented.blank?

        token = includes(grant: :client).find_by(token_digest: OauthServer.digest(presented), kind: kind)
        return Lookup.new(token: nil, refusal: :unknown) if token.nil?
        return Lookup.new(token: token, refusal: :revoked) if token.grant.revoked?
        return Lookup.new(token: token, refusal: :expired) if token.expires_at <= Time.current

        Lookup.new(token: token, refusal: nil)
      end

      # The `/mcp` side: is this bearer a live access token for this resource?
      def authenticate_access(presented, resource:)
        lookup = lookup(presented, kind: ACCESS)
        return lookup unless lookup.ok?
        return Lookup.new(token: lookup.token, refusal: :wrong_audience) unless lookup.grant.resource == resource

        lookup.token.mark_used!
        lookup.grant.touch_last_used!
        lookup
      end
    end

    # The first request an access token makes. Claims its pair (#claim_pair!) —
    # one write per access token, never repeated.
    def mark_used!
      claim_pair! if used_at.nil?
    end

    # This token's pair has reached its client: stamp both halves `used_at`, so
    # the evidence outlives the access token's own row, and retire any other
    # pair issued for the same spent refresh token (TokensController#rotate).
    # Called on an access token's first request and on a refresh token's
    # rotation — whichever comes first.
    def claim_pair!
      now = Time.current
      if rotated_from_id.nil?
        pair.where(used_at: nil).update_all(used_at: now, updated_at: now)
        return
      end

      grant.with_lock do
        # A sibling claimed first and retired this pair (unlinking it): leave
        # the winner alone.
        if self.class.where(id: id).where.not(rotated_from_id: nil).exists?
          pair.where(used_at: nil).update_all(used_at: now, updated_at: now)
          siblings = self.class.where(rotated_from_id: rotated_from_id).where.not(created_at: created_at)
          siblings.where(kind: REFRESH).update_all(rotated_at: now, rotated_from_id: nil, updated_at: now)
          siblings.where(kind: ACCESS).update_all(expires_at: now, rotated_from_id: nil, updated_at: now)
        end
      end
    end

    # The pair this refresh token's rotation issued, still linked to it.
    def successors
      self.class.where(rotated_from_id: id)
    end

    # Whether no pair this refresh token was traded for ever reached a client.
    # False when there is no linked pair at all — nothing shows one was lost.
    def successors_unused?
      issued = successors.to_a
      issued.any? && issued.none? { |token| token.used_at || token.rotated_at }
    end

    # Spend this refresh token. A conditional UPDATE, so of two concurrent
    # refreshes with the same token exactly one rotates it.
    #
    # @return [Boolean] true when this call spent it
    def rotate!
      self.class.where(id: id, rotated_at: nil).update_all(rotated_at: Time.current, updated_at: Time.current) == 1
    end

    private

    # The access and refresh token one Grant#issue_tokens! call minted together.
    def pair
      self.class.where(oauth_server_grant_id: oauth_server_grant_id, rotated_from_id: rotated_from_id, created_at: created_at)
    end
  end
end
