# frozen_string_literal: true

module Mcp
  module Tools
    # The receiving half of a cross-Zimmer merge approval, read side: which
    # session here holds a PR, its head commit on GitHub right now, and whether
    # this Zimmer would accept an approval for it from the asking issuer. The
    # issuing Zimmer reads the PR back to the person from this answer, so what
    # they say yes to is this Zimmer's account of the PR. See MergeAttestations.
    #
    # In the opt-in `merge_attestations` group with SubmitMergeAttestation.
    class GetMergeAttestationTarget < Tool
      tool_name MergeAttestations::TARGET_TOOL

      description <<~DESC
        For another Zimmer deployment that is about to ask a person to approve merging a pull request a session on THIS Zimmer holds. Answers JSON: the holding session, the PR's head commit on GitHub now, why it cannot be merged (`blocked_reason`, null when it can), why the merge gate held it, this Zimmer's audience name, and whether it trusts the given issuer's signed approvals.

        Read-only. A signed approval must name exactly this `head_sha`; submit it with `submit_merge_attestation`. Agents do not need this tool: approvals are minted by Zimmer itself from a person's confirmed yes, never by an agent.
      DESC

      input_schema({
        type: "object",
        properties: {
          pr_url: { type: "string", description: "The GitHub pull request URL, e.g. https://github.com/owner/repo/pull/123" },
          issuer: { type: "string", description: "The asking Zimmer's issuer name (its base URL), to report whether it is trusted here." },
          kid: { type: "string", description: "The id of the key the asking Zimmer signs with, to report whether that key is pinned here." }
        },
        required: [ "pr_url" ]
      })

      def call(args)
        pr_url = require_arg(args, "pr_url").to_s.strip
        target = MergeAttestations::Target.for(pr_url)
        session = target.session
        trust = MergeAttestations::Trust.current
        issuer = trust.issuer(args["issuer"].to_s.presence)
        kid = args["kid"].to_s.presence

        {
          pr_url: pr_url,
          repo: target.repo,
          pr_number: target.pr_number,
          head_sha: target.head_sha,
          session_id: session&.id,
          session_url: session && "#{AppUrl.base_url}/sessions/#{session.id}",
          title: session&.title,
          blocked_reason: target.blocked_reason,
          gate_hold_reason: target.ok? ? LiveConversations::AuthorizeMerge.latest_gate_hold_reason(pr_url) : nil,
          audience: MergeAttestations.audience,
          trusts_issuer: issuer.present? && (kid.nil? || issuer.key_for(kid).present?),
          # A merge this Zimmer already told the holding session to make, and
          # that has not since come back unmade (Sessions::AuthorizeMerge.authorized_at).
          merge_authorized_at: session && Sessions::AuthorizeMerge.authorized_at(session, pr_url)
        }.to_json
      end
    end
  end
end
