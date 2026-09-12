# frozen_string_literal: true

module Sessions
  # What a session's pull requests look like right now, read once.
  #
  # Three parallel hashes on `custom_metadata` describe a session's PRs — the
  # urls, their lifecycle state, and the CI verdict on the open ones — and they
  # are written by Github::PrStatusEvaluator. Four surfaces now ask the same
  # question of them (the User view's row, the Merge button's guard, the merge
  # authorization itself, and the `get_user_view` MCP tool), so the digging lives
  # here rather than four times over.
  #
  # "The PR" is the LAST url in the list, which is the same PR
  # `_github_pr_link` calls primary and shows first: a session that opened a
  # follow-up PR is asking about the follow-up.
  class PrSummary
    # A PR is mergeable from the dashboard when it is open and CI has gone green
    # on it. Nothing else counts as green: `pending` is a run in progress,
    # `skipping`/`cancel` are checks that never reported, and a key that is
    # absent means GitHub answered and the PR has no checks configured at all.
    # Offering a merge on any of those would be offering to merge something
    # nobody has verified.
    CI_GREEN = "pass"

    STATUS_OPEN = "open"
    STATUS_MERGED = "merged"

    # @param session [Session]
    def self.for(session)
      new(session)
    end

    def initialize(session)
      metadata = session.custom_metadata || {}
      @urls = Array(metadata["github_pull_request_urls"])
      @statuses = metadata["github_pull_request_statuses"] || {}
      @ci_statuses = metadata["github_pull_request_ci_statuses"] || {}
    end

    attr_reader :urls

    def any?
      url.present?
    end

    # The PR this session is currently about — the most recently recorded one.
    def url
      @urls.last
    end

    def count
      @urls.size
    end

    # "open", "merged", "closed", or nil when the poller has not rated it yet.
    def status
      return nil if url.blank?

      @statuses[url].presence
    end

    # "pass", "fail", "pending", "cancel", "skipping", or nil.
    def ci_status
      return nil if url.blank?

      @ci_statuses[url].presence
    end

    def open? = status == STATUS_OPEN
    def merged? = status == STATUS_MERGED

    # The one question the Merge button asks.
    def mergeable?
      open? && ci_status == CI_GREEN
    end

    # Why the Merge button is not offered, as a sentence for its tooltip. nil when
    # it IS offered — a caller can render the button exactly when this is nil.
    def merge_blocked_reason
      return "This session has no PR." if url.blank?
      return "Already merged." if merged?
      # The poller rates a PR within a poll or two of it being recorded, so this
      # is a brief window rather than a dead end — and it is not "open".
      return "Zimmer has not read this PR's state yet." if status.blank?
      return "The PR is #{status}." unless open?

      case ci_status
      when CI_GREEN then nil
      when nil then "CI has not reported on this PR."
      else "CI is #{ci_status}."
      end
    end
  end
end
