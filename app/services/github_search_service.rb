# frozen_string_literal: true

require "open3"

# Thin wrapper over GitHub's issue/PR search API, used by GithubTriggerPollerJob.
#
# Shells out to the `gh` CLI, exactly as GithubCommentPollerJob does, so it reuses
# the host's existing GitHub credential rather than introducing a second one.
#
# ## Why every query pins advanced_search=true
#
# GitHub is migrating the issue search API to its "advanced" query syntax. The two
# syntaxes are mutually incompatible for the multi-repo query this poller is built
# on, and neither form works under both:
#
#   legacy    repo:a repo:b        -> implicit OR;  `(repo:a OR repo:b)` is a 422
#   advanced  (repo:a OR repo:b)   -> explicit OR;  `repo:a repo:b` returns 0 rows
#
# The advanced form's failure mode is the dangerous one: a silent zero, not an error.
# Under the poller's seen-set semantics an empty result means "nothing carries the
# label", so a query that started being evaluated as advanced without us noticing
# would quietly drain the seen-set and then re-fire every labelled item the moment
# the syntax was corrected. Pinning the parameter means the syntax we build is the
# syntax GitHub evaluates, whichever default the API settles on.
class GithubSearchService
  class SearchError < StandardError; end

  PER_PAGE = 100

  # GitHub's search API tops out at 1000 results, which is these 10 pages. A query
  # needing more than that is misconfigured (a label on every open issue, say), and
  # a truncated read would corrupt the poller's seen-set, so we raise instead.
  MAX_PAGES = 10

  class << self
    # Whether the `gh` CLI can actually authenticate to GitHub from this process —
    # via a stored `gh auth login` credential OR a GH_TOKEN/GITHUB_TOKEN in the
    # environment, both of which `gh auth status` recognizes.
    #
    # This is the GitHub analogue of SlackService.configured?, and the poller guards
    # on it the same way SlackTriggerPollerJob guards on that. The staging worker ships
    # no gh credential, so without this every tick shelled out N times, each failing
    # with "please run: gh auth login", and each failure alerted — an every-minute
    # error storm over a missing credential the poller can simply detect and skip.
    #
    # Kept deliberately distinct from a transient API failure: an *unconfigured*
    # environment is not an incident (skip quietly), whereas a rate-limit or network
    # error on a configured host still raises out of search_issues and alerts.
    def configured?
      _out, _err, status = Open3.capture3("gh", "auth", "status")
      status.success?
    rescue => e
      Rails.logger.warn "[GithubSearchService] gh auth preflight failed: #{e.class}: #{e.message}"
      false
    end

    # Runs a search query and returns every matching item.
    #
    # Raises rather than returning a partial result. The poller derives its seen-set
    # from the full result, so a short read would look like "these items lost their
    # label" and re-fire them on the next tick.
    def search_issues(query, sort: nil, order: nil)
      items = []
      page = 1

      loop do
        payload = request(query, page: page, sort: sort, order: order)

        # A timed-out search returns whatever it managed to index. Treating that as
        # the complete picture would shrink the seen-set, so refuse the whole tick.
        if payload["incomplete_results"]
          raise SearchError, "GitHub search returned incomplete results for query: #{query}"
        end

        page_items = payload["items"] || []
        items.concat(page_items)

        total = payload["total_count"].to_i
        break if page_items.empty? || items.length >= total

        page += 1
        if page > MAX_PAGES
          raise SearchError, "GitHub search matched more than #{MAX_PAGES * PER_PAGE} items " \
                             "(total_count=#{total}) for query: #{query}"
        end
      end

      items
    end

    # ["owner/a", "owner/b"] -> (repo:owner/a OR repo:owner/b)
    #
    # Repo names are validated against TriggerCondition::GITHUB_REPO_FORMAT before
    # they are stored, so they cannot contain whitespace or quoting metacharacters.
    def repo_group(repos)
      or_group(repos.map { |repo| "repo:#{repo}" })
    end

    # ["ready to merge", "urgent"] -> (label:"ready to merge" OR label:"urgent")
    #
    # Labels are free text and routinely contain spaces, so each is quoted. An
    # embedded double quote would terminate the qualifier early, and GitHub has no
    # escape for it, so it is dropped rather than allowed to reshape the query.
    def label_group(labels)
      or_group(labels.map { |label| %(label:"#{label.to_s.delete('"')}") })
    end

    private

    def or_group(terms)
      "(#{terms.join(' OR ')})"
    end

    def request(query, page:, sort:, order:)
      command = [
        "gh", "api", "-X", "GET", "search/issues",
        "--raw-field", "q=#{query}",
        "--field", "advanced_search=true",
        "--field", "per_page=#{PER_PAGE}",
        "--field", "page=#{page}"
      ]
      command.push("--field", "sort=#{sort}") if sort.present?
      command.push("--field", "order=#{order}") if order.present?

      stdout, stderr, status = Open3.capture3(*command)

      unless status.success?
        detail = stderr.to_s.strip.presence || "exit status #{status.exitstatus}"
        raise SearchError, "gh api search/issues failed: #{detail}"
      end

      JSON.parse(stdout)
    rescue JSON::ParserError => e
      raise SearchError, "Could not parse GitHub search response: #{e.message}"
    end
  end
end
