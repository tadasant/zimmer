# frozen_string_literal: true

require "ostruct"

# Shared setup for the GitHub webhook tests: a webhook secret, the ingest mode, session spawning
# stubbed at the service boundary, and exactly one enabled trigger with every other switched off,
# so "exactly one session" means that trigger's session.
module GithubWebhookTestHelpers
  WEBHOOK_SECRET = "gh-webhook-secret-for-tests"
  REPO = "tadasant/zimmer"
  LABEL = "ready to merge"
  ENV_KEYS = %w[GITHUB_TRIGGER_INGEST_MODE GITHUB_WEBHOOK_SECRET].freeze

  def setup_github_webhook(mode: "webhook_with_poll_fallback", secret: WEBHOOK_SECRET)
    @saved_github_webhook_env = ENV_KEYS.to_h { |key| [ key, ENV[key] ] }
    ENV_KEYS.each { |key| ENV.delete(key) }
    ENV["GITHUB_TRIGGER_INGEST_MODE"] = mode if mode
    ENV["GITHUB_WEBHOOK_SECRET"] = secret if secret

    AgentRootsConfig.stubs(:find!).returns(
      OpenStruct.new(url: "https://github.com/test/repo", default_branch: "main", subdirectory: nil)
    )
    AgentSessionJob.stubs(:enqueue_new_session)

    @trigger = triggers(:github_issue_trigger)
    @condition = trigger_conditions(:github_issue_condition)
    Trigger.where.not(id: @trigger.id).update_all(status: "disabled")

    # A condition the poller has already baselined, with a cursor an hour back: the state a live
    # condition is in when a new issue is opened.
    @cursor = 1.hour.ago.utc.iso8601
    configure_condition(@condition.configuration.merge("last_issue_at" => @cursor, "seen_issue_keys" => [], "issue_repo_baselines" => {}))
  end

  # The same, for the `github_label` fixture: the merge gate's shape — PRs in one repo carrying one
  # label — already baselined by the poller with nothing labelled, which is where a live condition
  # sits the moment before a label is added.
  def setup_github_label_webhook(mode: "webhook_with_poll_fallback")
    setup_github_webhook(mode: mode)

    @trigger = triggers(:github_label_trigger)
    @condition = trigger_conditions(:github_label_condition)
    Trigger.where.not(id: @trigger.id).update_all(status: "disabled")
    @trigger.update_columns(status: "enabled")
    configure_condition(@condition.configuration.merge("seen_items" => [], "seen_missing_counts" => {}))
  end

  def teardown_github_webhook
    @saved_github_webhook_env&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Mocha::Mockery.instance.teardown
  end

  # Replace the fixture condition's configuration without its callbacks, which would otherwise
  # rebase the cursor or merge poll state across.
  def configure_condition(configuration)
    @condition.update_columns(configuration: configuration)
    @condition.reload
  end

  # An issue as GitHub's `issues` webhook payload carries it: the fields the poller reads, plus
  # some it does not, so a test can see what is dropped.
  def github_issue(number: 4242, title: "Build is red on main", body: "The deploy job failed.", labels: [],
                   created_at: Time.current.utc.iso8601, repo: REPO, pull_request: false)
    {
      "id" => 1_000_000 + number, "node_id" => "I_kwDO#{number}", "number" => number, "title" => title, "body" => body,
      "html_url" => "https://github.com/#{repo}/issues/#{number}",
      "repository_url" => "https://api.github.com/repos/#{repo}",
      "user" => { "login" => "octocat", "id" => 1 },
      "labels" => labels.map { |name| { "id" => 7, "name" => name, "color" => "d73a4a" } },
      "state" => "open", "created_at" => created_at, "updated_at" => created_at,
      "pull_request" => (pull_request ? { "url" => "https://api.github.com/repos/#{repo}/pulls/#{number}" } : nil)
    }.compact
  end

  def issues_payload(issue, action: "opened", label: nil)
    {
      "action" => action, "issue" => issue, "repository" => { "full_name" => REPO },
      "label" => (label ? { "id" => 7, "name" => label, "color" => "0e8a16" } : nil),
      "sender" => { "login" => "octocat" }
    }.compact
  end

  # A pull request as GitHub's `pull_request` webhook payload carries it. Deliberately NOT an issue
  # with a `pull_request` key bolted on: the real payload object has no `repository_url` at all,
  # which is the field the poller reads a repo out of.
  def github_pull_request(number: 4242, title: "Bump the thing", body: "Bumps it.", labels: [],
                          created_at: Time.current.utc.iso8601, repo: REPO, state: "open")
    {
      "id" => 2_000_000 + number, "node_id" => "PR_kwDO#{number}", "number" => number, "title" => title, "body" => body,
      "html_url" => "https://github.com/#{repo}/pull/#{number}",
      "url" => "https://api.github.com/repos/#{repo}/pulls/#{number}",
      "issue_url" => "https://api.github.com/repos/#{repo}/issues/#{number}",
      "user" => { "login" => "octocat", "id" => 1 },
      "labels" => labels.map { |name| { "id" => 7, "name" => name, "color" => "0e8a16" } },
      "state" => state, "draft" => false, "created_at" => created_at, "updated_at" => created_at,
      "base" => { "repo" => { "full_name" => repo } }, "head" => { "ref" => "feature" }
    }
  end

  def pull_request_payload(pull_request, action: "opened", label: nil, repo: REPO)
    {
      "action" => action, "number" => pull_request["number"], "pull_request" => pull_request,
      "repository" => { "full_name" => repo },
      "label" => (label ? { "id" => 7, "name" => label, "color" => "0e8a16" } : nil),
      "sender" => { "login" => "octocat" }
    }.compact
  end

  # The same pull request as the search API returns it to the poller: a repository_url, and a
  # `pull_request` sub-object in place of the payload's own shape.
  def searched_pull_request(pull_request, repo: REPO)
    pull_request.slice("number", "title", "body", "html_url", "user", "labels", "created_at", "state").merge(
      "repository_url" => "https://api.github.com/repos/#{repo}",
      "pull_request" => { "url" => pull_request["url"] }
    )
  end

  # Run the real poller over +items+ as if the label search had returned them.
  def poll_label_items(items)
    GithubSearchService.stubs(:search_issues).returns(items)
    GithubTriggerPollerJob.new.send(:process_condition, @condition.reload)
  end

  # The same issue as the search API returns it to the poller.
  def searched_issue(issue)
    issue.slice("number", "title", "body", "html_url", "repository_url", "user", "labels", "created_at", "pull_request")
  end

  # Run the real poller over +items+ as if the search had returned them.
  def poll_issues(items)
    GithubSearchService.stubs(:search_issues).returns(items)
    GithubTriggerPollerJob.new.send(:process_condition, @condition.reload)
  end
end
