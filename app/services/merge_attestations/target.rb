# frozen_string_literal: true

module MergeAttestations
  # On a receiving Zimmer: which session here holds a pull request, and what
  # an approval for it would have to name. What the issuer reads back to the
  # person comes from here, so the person hears this Zimmer's account of the
  # PR, and the head SHA they approve is the one this Zimmer will check.
  class Target
    # @param session [Session, nil] the session holding the PR, newest first
    # @param head_sha [String, nil] the PR's head on GitHub right now
    # @param pr_state [String, nil] GitHub's state: OPEN, MERGED, CLOSED
    Result = Data.define(:pr_url, :repo, :pr_number, :session, :head_sha, :pr_state, :blocked_reason) do
      def ok? = blocked_reason.nil?
    end

    # The newest unarchived session whose PR (Sessions::PrSummary#url) this is.
    def self.holding_session(pr_url)
      Session.where.not(status: :archived)
             .where("custom_metadata -> 'github_pull_request_urls' @> ?", [ pr_url ].to_json)
             .order(id: :desc).limit(20)
             .find { |session| Sessions::PrSummary.for(session).url == pr_url }
    end

    # @param snapshot [#call] reads the PR off GitHub; Github::PrSnapshot.fetch in production
    def self.for(pr_url, snapshot: ->(ref) { Github::PrSnapshot.fetch(ref) })
      repo, number = MergeAttestations.parse_pr_url(pr_url)
      return Result.new(pr_url: pr_url, repo: nil, pr_number: nil, session: nil, head_sha: nil, pr_state: nil,
                        blocked_reason: "That is not a GitHub pull request URL.") unless repo

      session = holding_session(pr_url)
      blocked = nil
      blocked = "No session on this Zimmer holds #{pr_url}." if session.nil?
      blocked ||= Sessions::PrSummary.for(session).merge_blocked_reason

      reading = blocked ? nil : snapshot.call(Github::PrRef.parse(pr_url))
      unless blocked
        blocked = "GitHub could not be read for #{pr_url} just now." if reading.nil?
        blocked ||= "GitHub says the PR is #{reading.state.to_s.downcase}." unless reading.state == "OPEN"
        blocked ||= "GitHub did not report the PR's head commit." unless reading.head_sha.to_s.match?(SHA)
      end

      Result.new(pr_url: pr_url, repo: repo, pr_number: number, session: session, head_sha: reading&.head_sha,
                 pr_state: reading&.state, blocked_reason: blocked)
    end
  end
end
