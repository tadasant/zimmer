# frozen_string_literal: true

module OauthServer
  # An access or refresh token. Only the digest is stored. A token is good while
  # it is unexpired and its grant is unrevoked; a refresh token is also spent by
  # the exchange that rotates it (`rotated_at`).
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

        lookup.grant.touch_last_used!
        lookup
      end
    end

    # Spend this refresh token. A conditional UPDATE, so of two concurrent
    # refreshes with the same token exactly one rotates it.
    #
    # @return [Boolean] true when this call spent it
    def rotate!
      self.class.where(id: id, rotated_at: nil).update_all(rotated_at: Time.current, updated_at: Time.current) == 1
    end
  end
end
