# frozen_string_literal: true

# GET /.well-known/merge-attestation-jwks.json — this Zimmer's public signing
# key for cross-deployment merge approvals (MergeAttestations), as a JWKS.
#
# Public on purpose: a public key is not a secret, and whoever configures a
# receiving Zimmer copies the key from here into its
# MERGE_ATTESTATION_TRUSTED_ISSUERS. Receivers pin it and never fetch it at
# verify time, so answering this URL is not a way to get trusted. Outside the
# web UI's sign-in gate, the way the OAuth discovery documents are; an edge
# that gates the whole host still gates it.
class MergeAttestationKeysController < ActionController::API
  def show
    response.set_header("Cache-Control", "public, max-age=300")
    keys = MergeAttestations::SigningKey.configured? ? [ MergeAttestations::SigningKey.current.public_jwk ] : []
    render json: { issuer: MergeAttestations.issuer, keys: keys }
  rescue MergeAttestations::SigningKey::NotConfigured => e
    Rails.logger.error("[MergeAttestationKeys] #{e.message}")
    render json: { issuer: MergeAttestations.issuer, keys: [] }
  end
end
