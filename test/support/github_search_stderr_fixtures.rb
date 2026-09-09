# frozen_string_literal: true

# Verbatim `gh` stderr captured from production, shared by the GithubSearchService and
# GithubTriggerPollerJob suites so the two cannot drift apart. Both classify against these
# exact strings, and a classifier that stops recognising the text GitHub actually emits is
# the failure these fixtures exist to catch — so they are copied, never paraphrased.
module GithubSearchStderrFixtures
  # 2026-09-09T14:01:08Z, condition 353. Request id and Terms-of-Service prose included:
  # `gh` inlines the whole response body, and the classifier has to cope with that.
  SECONDARY_RATE_LIMIT =
    "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try " \
    "again. For more on scraping GitHub and how it may affect your rights, please review our " \
    "Terms of Service (https://docs.github.com/en/site-policy/github-terms/github-terms-of-service) " \
    "If you reach out to GitHub Support for help, please include the request ID " \
    "BC20:B1444:DF87E:2D510A:6AA166A3. (HTTP 403)"

  # The primary hourly quota, which GitHub also answers 403 rather than 429.
  PRIMARY_RATE_LIMIT = "gh: API rate limit exceeded for user ID 1. (HTTP 403)"

  # A permission denial: the same status as both of the above, and permanent. The pair is
  # the whole reason classification cannot be a status-code lookup.
  PERMISSION_DENIED = "gh: Resource not accessible by integration (HTTP 403)"
end
