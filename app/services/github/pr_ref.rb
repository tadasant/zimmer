# frozen_string_literal: true

module Github
  # One pull request a session is tracking, resolved from the url the session recorded.
  #
  # The url -> owner/repo/number parse used to be a verbatim triple, one copy in each
  # of the three GitHub pollers, and every `gh` argument built from those captures
  # carried its own copy of the note explaining why the pattern is what prevents path
  # injection. There is one copy now, and `Github::PrPollPass` resolves each session's
  # urls once per pass and hands the refs to the evaluators.
  class PrRef
    # The anchor for both facts: an url that matches has an owner and a repo with no
    # slashes in them and a number that is digits only, so nothing built from these
    # captures can escape the path it is interpolated into.
    URL_PATTERN = %r{github\.com/([^/]+)/([^/]+)/pull/(\d+)}

    attr_reader :url, :owner, :repo, :number

    # @param url [String]
    # @return [PrRef, nil] nil when the url is not a GitHub pull request url
    def self.parse(url)
      match = url.to_s.match(URL_PATTERN)
      return nil unless match

      new(url: url, owner: match[1], repo: match[2], number: match[3])
    end

    # Every tracked PR on a session, in the order the session recorded them.
    #
    # Sessions whose `github_pull_request_urls` is missing or not an array answer
    # with an empty list — the shape check the three pollers each made for
    # themselves.
    #
    # @param session [Session]
    # @return [Array<PrRef>]
    def self.for_session(session)
      urls = session.custom_metadata&.dig("github_pull_request_urls")
      return [] unless urls.is_a?(Array)

      urls.filter_map { |url| parse(url) }
    end

    def initialize(url:, owner:, repo:, number:)
      @url = url
      @owner = owner
      @repo = repo
      @number = number
    end

    # "owner/repo", the form `gh --repo` takes.
    def slug
      "#{owner}/#{repo}"
    end

    def to_s
      "#{slug}##{number}"
    end
  end
end
