# frozen_string_literal: true

module Mcp
  module Tools
    # The receiving half of a cross-Zimmer merge approval, write side: hand
    # over a signed approval, and if it verifies, the session holding the PR is
    # told to merge it exactly as a Merge-button tap here would tell it.
    #
    # Who calls this does not matter, which is the point: the authority is the
    # signature, checked against keys pinned in MERGE_ATTESTATION_TRUSTED_ISSUERS,
    # and the token is good for one PR, one commit, a few minutes and one use.
    # An agent that obtains a token can only deliver the approval the person
    # already gave. An agent cannot write one. See MergeAttestations::Acceptor.
    #
    # Refusals are answered as JSON, not as tool errors, so the issuing Zimmer
    # can read the reason code and tell the person what happened.
    class SubmitMergeAttestation < Tool
      tool_name MergeAttestations::SUBMIT_TOOL

      description <<~DESC
        Deliver a signed merge approval (a compact JWS, alg EdDSA) that another Zimmer deployment minted from a person's confirmed yes. If it verifies against a key this Zimmer pinned, names this Zimmer as its audience, is unexpired and unused, and names the PR's current head commit, the session holding the PR is sent the same human-authorized merge message the Merge button sends, pinned to that commit.

        Answers JSON: `accepted` (bool), `code` (a stable reason on refusal), `message`, and on acceptance the holding session. Agents cannot mint these; there is nothing to gain from calling this with anything but a token Zimmer handed over.
      DESC

      input_schema({
        type: "object",
        properties: {
          attestation: { type: "string", description: "The signed approval, header.payload.signature." }
        },
        required: [ "attestation" ]
      })

      def call(args)
        result = MergeAttestations::Acceptor.call(require_arg(args, "attestation").to_s)
        {
          accepted: result.attestation.outcome == "accepted", code: result.attestation.outcome, message: result.message,
          session_id: result.session.id, session_url: "#{AppUrl.base_url}/sessions/#{result.session.id}"
        }.to_json
      rescue MergeAttestations::Rejected => e
        Rails.logger.warn("[SubmitMergeAttestation] refused (#{e.code}): #{e.message}")
        { accepted: false, code: e.code, message: e.message }.to_json
      end
    end
  end
end
