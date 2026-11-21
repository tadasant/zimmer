# frozen_string_literal: true

module MergeAttestations
  # On a receiving Zimmer: a signed approval in, a merge authorization out.
  #
  # 1. Verifier checks the token itself: pinned key, audience, expiry, claims.
  # 2. Target checks the world: a session here holds the PR, the PR is open and
  #    green, and its head on GitHub right now is the commit the person
  #    approved. A push since the yes refuses it.
  # 3. One transaction claims the `jti` (a unique insert, so a replay loses),
  #    writes the `attested` HumanMessage on the holding session, and appends a
  #    `human_approved` row to the PR merge gate's ledger.
  # 4. Sessions::AuthorizeMerge tells the holding session to merge, the same
  #    message a Merge-button tap sends, pinned to the approved commit.
  #
  # A token that fails 1 or 2 leaves nothing but a log line and the refusal,
  # so a caller can retry with a fresh approval. One that passes is spent,
  # whether or not the session could take the message; only one the session
  # took is answered `accepted`.
  class Acceptor
    Result = Data.define(:attestation, :session, :message)

    def self.call(token, **) = new(**).call(token)

    def initialize(verifier: Verifier.new, snapshot: nil)
      @verifier = verifier
      @snapshot = snapshot
    end

    # @return [Result]
    # @raise [Rejected]
    def call(token)
      claims = @verifier.verify!(token)
      target = @snapshot ? Target.for(claims.pr_url, snapshot: @snapshot) : Target.for(claims.pr_url)
      raise Rejected.new("not_mergeable", "Refused: #{target.blocked_reason}") unless target.ok?
      unless target.head_sha == claims.head_sha
        raise Rejected.new("head_moved", "Refused: the person approved commit #{claims.head_sha[0, 12]}, and the PR's head is " \
                                         "now #{target.head_sha.to_s[0, 12]}. A new commit needs a new yes.")
      end

      session = target.session
      attestation = record!(claims, session)

      begin
        result = Sessions::AuthorizeMerge.call(
          session: session,
          surface: "#{claims.channel == 'live_mode' ? 'Zimmer Live Mode' : claims.channel} at #{claims.iss}",
          act: "said yes to #{claims.iss}'s read-back of this PR (\"#{claims.read_back.truncate(160)}\"; they answered " \
               "\"#{claims.answer.truncate(60)}\"), which that Zimmer signed and this one verified",
          head_sha: claims.head_sha
        )
      rescue => e
        attestation.update!(outcome: "undeliverable", outcome_detail: "#{e.class}: #{e.message}".truncate(1_000))
        raise Rejected.new("undeliverable", "Verified, but the merge message could not be sent: #{e.message.truncate(200)}")
      end
      attestation.update!(outcome: result.ok? ? "accepted" : "undeliverable", outcome_detail: result.message)
      log(session, claims, result)
      Result.new(attestation: attestation, session: session, message: result.message)
    end

    private

    def record!(claims, session)
      MergeAttestation.transaction do
        attestation = MergeAttestation.create!(
          direction: MergeAttestation::RECEIVED, jti: claims.jti, issuer: claims.iss, audience: claims.aud, key_id: claims.kid,
          pr_url: claims.pr_url, repo: claims.repo, pr_number: claims.pr_number, head_sha: claims.head_sha,
          approver: claims.local_approver, approver_name: claims.approver_name, channel: claims.channel, surface: claims.surface,
          read_back: claims.read_back, answer: claims.answer, approved_at: claims.approved_at, issued_at: claims.issued_at,
          expires_at: claims.expires_at, session: session, claims: claims.raw
        )
        message = HumanMessageCapture.record_attested_merge_approval!(session: session, claims: claims, attestation: attestation)
        attestation.update!(human_message: message)
        GateDecisions::Record.call(
          gate: GateDecision::PR_MERGE,
          surface: gate_surface(session, claims),
          recorded_via: GateDecision::ATTESTATION,
          entry: {
            "pr" => claims.pr_url,
            "decided_at" => Date.current.iso8601,
            "decision" => GateDecision::HUMAN_APPROVED,
            "title" => session.title.to_s.presence,
            "producing_session" => "#{AppUrl.base_url}/sessions/#{session.id}",
            "human_approval" => {
              "issuer" => claims.iss, "jti" => claims.jti, "key_id" => claims.kid, "approver" => claims.local_approver,
              "remote_approver" => claims.approver, "channel" => claims.channel, "surface" => claims.surface,
              "head_sha" => claims.head_sha, "read_back" => claims.read_back, "answer" => claims.answer,
              "approved_at" => claims.approved_at.utc.iso8601, "human_message_id" => message.id,
              "merge_attestation_id" => attestation.id
            }.compact
          }
        )
        attestation
      end
    rescue ActiveRecord::RecordNotUnique
      raise Rejected.new("replayed", "Refused: this approval (#{claims.jti}) has already been used.")
    end

    # The ledger's surfaces are agent roots, so the row lands beside the gate's
    # own ratings for the same root.
    def gate_surface(session, claims)
      GateDecision.normalize_surface(session.agent_root_key.presence || session.agent_root_name.presence || claims.repo.split("/").last)
    end

    def log(session, claims, result)
      session.logs.create!(
        level: "info",
        content: "Signed merge approval from #{claims.iss} for #{claims.pr_url} at #{claims.head_sha[0, 12]} " \
                 "(#{claims.approver_name || claims.approver}, #{[ claims.channel, claims.surface ].compact.join('/')}): " \
                 "#{result.message}"
      )
    rescue => e
      Rails.logger.warn("[MergeAttestations::Acceptor] could not log on session #{session.id}: #{e.message}")
    end
  end
end
