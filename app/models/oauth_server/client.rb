# frozen_string_literal: true

module OauthServer
  # A client of Zimmer's authorization server. Every client is public: it proves
  # possession with PKCE, not with a secret, so a row holds no credential.
  #
  # Two ways in, recorded in `registration_type`:
  #
  # - **`dcr`** — `POST /oauth/register` (RFC 7591). Zimmer mints the `client_id`.
  # - **`cimd`** — the `client_id` is an HTTPS URL whose JSON document lists the
  #   client's redirect URIs (draft-ietf-oauth-client-id-metadata-document). The
  #   row is a cache of that document, re-fetched once `metadata_expires_at`
  #   passes. See OauthServer::ClientMetadataDocument.
  #
  # And one way that is not a registration at all: **`first_party`**, Zimmer's
  # own iOS app, built in under a fixed `client_id`. See OauthServer::NativeApp.
  class Client < ApplicationRecord
    DCR = "dcr"
    CIMD = "cimd"
    FIRST_PARTY = "first_party"
    REGISTRATION_TYPES = [ DCR, CIMD, FIRST_PARTY ].freeze

    DCR_CLIENT_ID_PREFIX = "zmc_"

    has_many :authorization_codes, class_name: "OauthServer::AuthorizationCode",
      foreign_key: :oauth_server_client_id, inverse_of: :client, dependent: :delete_all
    has_many :grants, class_name: "OauthServer::Grant",
      foreign_key: :oauth_server_client_id, inverse_of: :client, dependent: :destroy

    validates :client_id, presence: true, uniqueness: true
    validates :registration_type, inclusion: { in: REGISTRATION_TYPES }
    validate :redirect_uris_present

    # A client nobody ever consented to — a DCR registration, or a cached
    # metadata document gone stale — is pruned after this long, so neither open
    # registration nor document fetches can grow the table without bound.
    UNUSED_CLIENT_RETENTION = 7.days

    scope :dcr, -> { where(registration_type: DCR) }

    class << self
      # The client named by an authorization request: a DCR registration, or a
      # metadata document fetched (or re-fetched, once stale) from its URL.
      #
      # @raise [OauthServer::Error] invalid_client
      def resolve!(client_id)
        client_id = client_id.to_s
        raise Error.new("invalid_client", "client_id is required") if client_id.blank?
        return NativeApp.client if NativeApp.client_id?(client_id)
        return ClientMetadataDocument.resolve!(client_id) if ClientMetadataDocument.url_client_id?(client_id)

        dcr.find_by(client_id: client_id) || raise(Error.new("invalid_client", "unknown client_id"))
      end

      # The client named at the token endpoint. A CIMD document is not re-fetched
      # here: the code or refresh token is already bound to this row.
      def find_known!(client_id)
        find_by(client_id: client_id.to_s.presence) || raise(Error.new("invalid_client", "unknown client_id"))
      end

      # RFC 7591 registration from a parsed JSON body.
      def register!(doc)
        parsed = ClientMetadata.parse!(doc)
        prune_unused_registrations

        create!(
          client_id: "#{DCR_CLIENT_ID_PREFIX}#{SecureRandom.hex(16)}",
          registration_type: DCR,
          client_name: parsed.client_name,
          client_uri: parsed.client_uri,
          redirect_uris: parsed.redirect_uris,
          grant_types: parsed.grant_types
        )
      end

      def prune_unused_registrations
        cutoff = UNUSED_CLIENT_RETENTION.ago
        unused = where.missing(:grants)
        unused.dcr.where(created_at: ...cutoff).delete_all
        unused.where(registration_type: CIMD, metadata_expires_at: ...cutoff).delete_all
      end
    end

    def cimd? = registration_type == CIMD

    def first_party? = registration_type == FIRST_PARTY

    def metadata_stale?(now = Time.current)
      metadata_expires_at.nil? || metadata_expires_at <= now
    end

    # The host that published a CIMD client's document — the one thing on the
    # consent screen that is not the client's own claim.
    def publisher_host
      URI.parse(client_id).host if cimd?
    end

    def redirect_uri_registered?(uri)
      redirect_uris.include?(uri)
    end

    def touch_last_used!
      update_column(:last_used_at, Time.current) if last_used_at.nil? || last_used_at < 1.minute.ago
    end

    private

    def redirect_uris_present
      errors.add(:redirect_uris, "must list at least one URI") unless redirect_uris.is_a?(Array) && redirect_uris.any?
    end
  end
end
