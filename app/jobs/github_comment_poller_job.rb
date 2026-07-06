require "open3"

# Job that polls GitHub PR comments for sessions with associated PRs
# Runs every 30 seconds via GoodJob cron configuration
#
# Tracks comments in custom_metadata as github_comments:
# {
#   "github_comments" => {
#     "https://github.com/owner/repo/pull/123" => {
#       "pr_comments" => [
#         { "id" => 123, "author" => "user", "attribution" => "user", "body" => "...", "url" => "...", "created_at" => "..." },
#         { "id" => 456, "author" => "agent-user", "attribution" => "self", "body" => "[CC Says]...", "url" => "...", "created_at" => "..." }
#       ],
#       "review_comments" => [
#         { "id" => 789, "author" => "user", "attribution" => "user", "body" => "...", "url" => "...", "path" => "...", "line" => 42, "diff_hunk" => "...", "created_at" => "..." }
#       ]
#     }
#   }
# }
#
# Attribution logic:
# - Comments containing "[CC Says]" are attributed to "self" (the agent)
# - All other comments are attributed to the author username
#
# When a whitelisted user (tadasant, macoughl) makes a new comment,
# a follow-up prompt is automatically enqueued for the session.
#
class GithubCommentPollerJob < ApplicationJob
  include DatabaseRetry

  queue_as :pollers

  # Singleton pattern: only allow one instance to run/queue at a time
  # This prevents queue backup when polling takes longer than the cron interval
  good_job_control_concurrency_with(
    key: -> { "github_comment_poller" },
    total_limit: 1
  )

  # Whitelisted users who can trigger agent responses via comments (case-insensitive)
  # GitHub usernames are case-insensitive, so we store lowercase and convert before comparison
  WHITELISTED_USERS = %w[tadasant macoughl].freeze

  # Marker that identifies agent-generated comments
  AGENT_COMMENT_MARKER = "[CC Says]"

  # Patterns that should be ignored when processing comments for follow-up prompts
  # These are typically bot commands or automated messages that shouldn't trigger agent responses
  BLACKLISTED_PATTERNS = [
    /\A\/deploy staging\z/i  # Exact match for "/deploy staging" command
  ].freeze

  # Maximum comments to fetch per API call (GitHub's default is 30, max is 100)
  MAX_COMMENTS_PER_PAGE = 100

  # Per-session backoff key + base cadence; see PollBackoff for the curve.
  POLL_BACKOFF_KEY = "github_comment_poller".freeze
  BASE_POLL_INTERVAL_SECONDS = 30

  def perform
    Session.with_github_prs.find_each do |session|
      unless PollBackoff.should_poll?(session, job_key: POLL_BACKOFF_KEY, base_interval: BASE_POLL_INTERVAL_SECONDS)
        Rails.logger.info "[GithubCommentPollerJob] Skipping session #{session.id} (PollBackoff: stale user activity)"
        next
      end

      poll_comments_for_session(session)
      PollBackoff.record_poll!(session, job_key: POLL_BACKOFF_KEY)
    rescue => e
      Rails.logger.error "[GithubCommentPollerJob] Error polling comments for session #{session.id}: #{e.message}"
    end
  end

  private

  def poll_comments_for_session(session)
    pr_urls = session.custom_metadata&.dig("github_pull_request_urls")
    return unless pr_urls.is_a?(Array) && pr_urls.present?

    current_comments = session.custom_metadata&.dig("github_comments") || {}
    tracking_timestamps = session.custom_metadata&.dig("github_pr_tracking_started_at") || {}
    updated_comments = current_comments.deep_dup
    new_user_comments = []

    pr_urls.each do |pr_url|
      match = pr_url.match(%r{github\.com/([^/]+)/([^/]+)/pull/(\d+)})
      next unless match

      owner, repo, pr_number = match.captures
      pr_key = pr_url

      # Get the timestamp when this PR started being tracked by this session
      # Only comments created after this time should trigger follow-up prompts
      tracking_started_at = tracking_timestamps[pr_key]

      # Initialize structure for this PR if needed
      updated_comments[pr_key] ||= { "pr_comments" => [], "review_comments" => [] }
      existing_pr_comments = updated_comments[pr_key]["pr_comments"] || []
      existing_review_comments = updated_comments[pr_key]["review_comments"] || []

      # Fetch PR-level comments (issue comments on the PR)
      pr_comments = fetch_pr_comments(owner, repo, pr_number)
      if pr_comments
        pr_comments.each do |comment|
          next if existing_pr_comments.any? { |c| c["id"] == comment["id"] }

          comment_data = build_pr_comment_data(comment, pr_url, pr_number)
          updated_comments[pr_key]["pr_comments"] << comment_data

          # Check if this is a new user comment from a whitelisted user (excluding blacklisted patterns)
          # Also check that the comment was created after we started tracking this PR
          if comment_data["attribution"] != "self" &&
             WHITELISTED_USERS.include?(comment_data["author"].downcase) &&
             !blacklisted_comment?(comment_data["body"]) &&
             comment_created_after_tracking_started?(comment_data, tracking_started_at)
            new_user_comments << { type: "pr", data: comment_data, pr_url: pr_url, owner: owner, repo: repo, pr_number: pr_number }
          end
        end
      end

      # Fetch review comments (inline comments on diffs)
      review_comments = fetch_review_comments(owner, repo, pr_number)
      if review_comments
        review_comments.each do |comment|
          next if existing_review_comments.any? { |c| c["id"] == comment["id"] }

          comment_data = build_review_comment_data(comment, pr_url, pr_number)
          updated_comments[pr_key]["review_comments"] << comment_data

          # Check if this is a new user comment from a whitelisted user (excluding blacklisted patterns)
          # Also check that the comment was created after we started tracking this PR
          if comment_data["attribution"] != "self" &&
             WHITELISTED_USERS.include?(comment_data["author"].downcase) &&
             !blacklisted_comment?(comment_data["body"]) &&
             comment_created_after_tracking_started?(comment_data, tracking_started_at)
            new_user_comments << { type: "review", data: comment_data, pr_url: pr_url, owner: owner, repo: repo, pr_number: pr_number }
          end
        end
      end
    end

    # Update session if comments changed
    if updated_comments != current_comments
      with_db_retry do
        session.update!(
          custom_metadata: (session.custom_metadata || {}).merge("github_comments" => updated_comments)
        )
      end
      Rails.logger.info "[GithubCommentPollerJob] Updated comments for session #{session.id}"
    end

    # Enqueue follow-up prompts for new user comments
    new_user_comments.each do |comment_info|
      enqueue_follow_up_prompt(session, comment_info)
    end
  end

  def fetch_pr_comments(owner, repo, pr_number)
    # Use gh CLI to get PR comments (issue comments) with pagination
    # Note: owner/repo are extracted via regex from validated PR URLs (github.com/[^/]+/[^/]+/pull/\d+)
    # which prevents path injection. pr_number is validated as digits only.
    fetch_paginated_comments("repos/#{owner}/#{repo}/issues/#{pr_number}/comments")
  end

  def fetch_review_comments(owner, repo, pr_number)
    # Use gh CLI to get review comments (inline comments on diffs) with pagination
    # Note: owner/repo are extracted via regex from validated PR URLs (github.com/[^/]+/[^/]+/pull/\d+)
    # which prevents path injection. pr_number is validated as digits only.
    fetch_paginated_comments("repos/#{owner}/#{repo}/pulls/#{pr_number}/comments")
  end

  # Fetches all comments from a paginated GitHub API endpoint
  # Returns all comments across all pages, or nil on failure
  def fetch_paginated_comments(api_path)
    all_comments = []
    page = 1

    loop do
      command = [
        "gh", "api",
        "#{api_path}?per_page=#{MAX_COMMENTS_PER_PAGE}&page=#{page}",
        "--jq", "."
      ]

      stdout, stderr, status = Open3.capture3(*command)

      unless status.success?
        Rails.logger.warn "[GithubCommentPollerJob] Failed to fetch comments from #{api_path} (page #{page}): #{stderr}"
        return all_comments.any? ? all_comments : nil
      end

      page_comments = JSON.parse(stdout)
      break if page_comments.empty?

      all_comments.concat(page_comments)
      break if page_comments.length < MAX_COMMENTS_PER_PAGE

      page += 1
    end

    all_comments
  rescue JSON::ParserError => e
    Rails.logger.error "[GithubCommentPollerJob] Failed to parse comments from #{api_path}: #{e.message}"
    all_comments.any? ? all_comments : nil
  end

  def build_pr_comment_data(comment, pr_url, pr_number)
    author = comment.dig("user", "login") || "unknown"
    body = comment["body"] || ""

    {
      "id" => comment["id"],
      "author" => author,
      "attribution" => body.include?(AGENT_COMMENT_MARKER) ? "self" : author,
      "body" => body,
      "url" => comment["html_url"],
      "created_at" => comment["created_at"]
    }
  end

  def build_review_comment_data(comment, pr_url, pr_number)
    author = comment.dig("user", "login") || "unknown"
    body = comment["body"] || ""

    {
      "id" => comment["id"],
      "author" => author,
      "attribution" => body.include?(AGENT_COMMENT_MARKER) ? "self" : author,
      "body" => body,
      "url" => comment["html_url"],
      "path" => comment["path"],
      "line" => comment["line"] || comment["original_line"],
      "diff_hunk" => comment["diff_hunk"],
      "in_reply_to_id" => comment["in_reply_to_id"],
      "created_at" => comment["created_at"]
    }
  end

  # Check if a comment body matches any blacklisted pattern
  # Used to filter out bot commands and automated messages
  def blacklisted_comment?(body)
    return false if body.blank?

    BLACKLISTED_PATTERNS.any? { |pattern| body.match?(pattern) }
  end

  # Check if a comment was created after tracking started for this PR
  # This prevents historical comments from being enqueued when a session
  # is associated with an existing PR that has prior comments
  #
  # @param comment_data [Hash] The comment data including "created_at" timestamp
  # @param tracking_started_at [String, nil] ISO8601 timestamp when tracking started, or nil if unknown
  # @return [Boolean] true if the comment should be processed, false if it's a historical comment
  def comment_created_after_tracking_started?(comment_data, tracking_started_at)
    # If we don't have a tracking timestamp (legacy sessions), allow all comments
    # This maintains backwards compatibility for sessions created before this feature
    return true if tracking_started_at.blank?

    comment_created_at = comment_data["created_at"]
    return true if comment_created_at.blank?

    begin
      # Parse both timestamps and compare
      # Comment must be created at or after tracking started
      Time.parse(comment_created_at) >= Time.parse(tracking_started_at)
    rescue ArgumentError => e
      Rails.logger.warn "[GithubCommentPollerJob] Failed to parse timestamp: #{e.message}"
      # If we can't parse timestamps, default to allowing the comment
      true
    end
  end

  # Add eyes emoji reaction to a GitHub comment to indicate we're processing it
  # Uses the GitHub API to create a reaction on the comment
  # This is best-effort and won't block the enqueue if it fails
  def add_eyes_reaction(comment_info)
    owner = comment_info[:owner]
    repo = comment_info[:repo]
    comment_id = comment_info.dig(:data, "id")
    comment_type = comment_info[:type]

    return unless comment_id

    # Different API endpoints for PR comments vs review comments
    api_path = if comment_type == "review"
      "repos/#{owner}/#{repo}/pulls/comments/#{comment_id}/reactions"
    else
      "repos/#{owner}/#{repo}/issues/comments/#{comment_id}/reactions"
    end

    command = [
      "gh", "api",
      "--method", "POST",
      api_path,
      "-f", "content=eyes"
    ]

    stdout, stderr, status = Open3.capture3(*command)

    unless status.success?
      Rails.logger.warn "[GithubCommentPollerJob] Failed to add eyes reaction to comment #{comment_id}: #{stderr}"
    end
  rescue StandardError => e
    # Don't let reaction failures prevent the follow-up prompt from being enqueued
    safe_comment_id = comment_info.dig(:data, "id") || "unknown"
    Rails.logger.warn "[GithubCommentPollerJob] Exception adding eyes reaction to comment #{safe_comment_id}: #{e.class} - #{e.message}"
  end

  def enqueue_follow_up_prompt(session, comment_info)
    # Add eyes emoji reaction to indicate we're processing the comment
    add_eyes_reaction(comment_info)

    prompt = GithubCommentPromptBuilder.new(
      session: session,
      comment_info: comment_info
    ).build

    return unless prompt.present?

    with_db_retry do
      # Use transaction with row-level locking to prevent race conditions
      # The state check and state change must happen atomically
      ActiveRecord::Base.transaction do
        # Lock the session row and reload to get current state
        session.lock!

        # If session is in needs_input state, send the message immediately
        # rather than queueing it (follows same pattern as SessionsController#follow_up)
        if session.needs_input?
          send_prompt_immediately(session, prompt, comment_info)
        else
          enqueue_prompt_for_later(session, prompt, comment_info)
        end
      end
    end
  rescue => e
    Rails.logger.error "[GithubCommentPollerJob] Failed to process follow-up prompt for session #{session.id}: #{e.message}"
  end

  # Send prompt directly to the session, transitioning it to running
  # Used when session is in needs_input state
  #
  # Note: This method must be called within a transaction that has already
  # locked the session row to prevent race conditions.
  #
  # Note: GitHub comments don't have goals. The session's existing
  # goal is preserved (not modified like in SessionsController#follow_up).
  def send_prompt_immediately(session, prompt, comment_info)
    comment_type = comment_info[:type] == "review" ? "review comment" : "PR comment"
    comment_url = comment_info[:data]["url"]
    truncated_prompt = prompt.length > 200 ? "#{prompt[0..197]}..." : prompt

    # Reset SIGTERM retry state for fresh execution
    # (matches SessionsController#follow_up pattern)
    if session.metadata&.dig("sigterm_retry_count").present?
      session.update!(
        metadata: (session.metadata || {}).except(
          "sigterm_retry_count",
          "sigterm_retry_timestamps",
          "last_sigterm_at"
        )
      )
    end

    # Transition to running first (matches SessionsController order)
    session.resume! if session.may_resume?

    # Log the immediate send
    session.logs.create!(
      content: "GitHub #{comment_type} from #{comment_info[:data]['author']} sent immediately (#{comment_url}): #{truncated_prompt}",
      level: "info"
    )

    # Store pending prompt in metadata for recovery if job interrupted
    # (stored after state transition to ensure state change is committed first)
    session.update!(
      metadata: (session.metadata || {}).merge("pending_follow_up_prompt" => prompt)
    )

    # Enqueue job to continue the session with the prompt
    AgentSessionJob.enqueue_with_prompt(session.id, prompt)

    Rails.logger.info "[GithubCommentPollerJob] Sent immediate follow-up prompt for session #{session.id} from GitHub #{comment_type} by #{comment_info[:data]['author']}"
  end

  # Queue prompt as an enqueued message for later processing
  # Used when session is running or waiting
  #
  # Note: This method must be called within a transaction that has already
  # locked the session row to prevent race conditions.
  def enqueue_prompt_for_later(session, prompt, comment_info)
    comment_type = comment_info[:type] == "review" ? "review comment" : "PR comment"
    comment_url = comment_info[:data]["url"]

    max_position = session.enqueued_messages.maximum(:position) || 0
    next_position = max_position + 1

    session.enqueued_messages.create!(
      content: prompt,
      position: next_position,
      status: "pending"
    )

    session.logs.create!(
      content: "GitHub #{comment_type} from #{comment_info[:data]['author']} auto-enqueued as follow-up prompt (#{comment_url})",
      level: "info"
    )

    Rails.logger.info "[GithubCommentPollerJob] Enqueued follow-up prompt for session #{session.id} from GitHub #{comment_type} by #{comment_info[:data]['author']}"
  end
end
