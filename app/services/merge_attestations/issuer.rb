# frozen_string_literal: true

module MergeAttestations
  # Signs one human merge approval and records it as `issued`.
  #
  # Called from exactly one place: LiveConversations::AuthorizeMerge#confirm,
  # after every check the voice Merge button makes on the person's yes has
  # passed and their words have been recorded as a `live_mode` HumanMessage.
  # That HumanMessage is required here, so a caller cannot sign for an approval
  # it has not first recorded as a person's. No MCP tool, REST endpoint or job
  # calls this; test/services/merge_attestations/issuer_test.rb holds the line.
  class Issuer
    # @param session [Session] the local session that drives the remote one
    # @param human_message [HumanMessage] the person's recorded yes, channel live_mode
    # @param target [Remote::Target] the remote's account of the PR, read at confirm time
    # @param remote [Remote]
    # @return [Array(String, MergeAttestation)] the token and its row
    def self.mint!(session:, human_message:, target:, remote:, read_back:, now: Time.current, key: SigningKey.current)
      raise ArgumentError, "a merge approval is signed only for a recorded live_mode yes" unless
        human_message.is_a?(HumanMessage) && human_message.persisted? && human_message.channel == HumanMessage::LIVE_MODE &&
        human_message.session_id == session.id
      raise ArgumentError, "the remote gave no head commit" unless target.head_sha.to_s.match?(SHA)

      repo, number = MergeAttestations.parse_pr_url(target.pr_url)
      raise ArgumentError, "not a pull request URL" unless repo

      issued_at = now.to_i
      approver = User.for_key(human_message.author)
      claims = {
        "iss" => MergeAttestations.issuer,
        "aud" => remote.audience,
        "sub" => target.pr_url,
        "jti" => SecureRandom.uuid,
        "iat" => issued_at,
        "exp" => issued_at + LIFETIME.to_i,
        "ver" => VERSION,
        "repo" => repo,
        "pr_number" => number,
        "head_sha" => target.head_sha,
        "approver" => human_message.author,
        "approver_name" => approver&.display_name,
        "channel" => HumanMessage::LIVE_MODE,
        "surface" => human_message.provenance["surface"],
        "heard" => human_message.provenance["heard"],
        "read_back" => read_back.to_s,
        "answer" => human_message.content,
        "approved_at" => human_message.occurred_at.utc.iso8601,
        "issuer_session_url" => "#{AppUrl.base_url}/sessions/#{session.id}",
        "human_message_id" => human_message.id,
        "remote_session_url" => target.session_url
      }.compact

      token = key.sign(claims)
      row = MergeAttestation.create!(
        direction: MergeAttestation::ISSUED, jti: claims["jti"], issuer: claims["iss"], audience: claims["aud"],
        key_id: key.kid, pr_url: target.pr_url, repo: repo, pr_number: number, head_sha: target.head_sha,
        approver: human_message.author, approver_name: claims["approver_name"], channel: claims["channel"],
        surface: claims["surface"], read_back: claims["read_back"], answer: claims["answer"],
        approved_at: human_message.occurred_at, issued_at: Time.zone.at(issued_at), expires_at: Time.zone.at(claims["exp"]),
        session: session, human_message: human_message, remote_server: remote.server_name,
        remote_session_url: target.session_url, claims: claims
      )
      [ token, row ]
    end
  end
end
