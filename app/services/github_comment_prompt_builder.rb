require "open3"

# Builds context-rich follow-up prompts from GitHub PR comments
#
# This service takes a GitHub comment and crafts an appropriate prompt for the agent.
# The prompt includes context (code, thread history) and instructions for how to respond.
# Intent determination (question vs change request) is left to the agent, not hardcoded.
#
# Usage:
#   builder = GithubCommentPromptBuilder.new(
#     session: session,
#     comment_info: { type: "review", data: comment_data, pr_url: "...", owner: "...", repo: "...", pr_number: "123" }
#   )
#   prompt = builder.build
#
class GithubCommentPromptBuilder
  attr_reader :session, :comment_info

  def initialize(session:, comment_info:)
    @session = session
    @comment_info = comment_info
  end

  def build
    comment_data = comment_info[:data]
    comment_type = comment_info[:type]
    pr_url = comment_info[:pr_url]

    body = comment_data["body"]
    author = comment_data["author"]
    comment_url = comment_data["url"]

    # Build context based on comment type
    context = build_context(comment_type, comment_data)

    # Build the prompt
    prompt = build_prompt(
      body: body,
      author: author,
      comment_url: comment_url,
      comment_type: comment_type,
      context: context,
      pr_url: pr_url
    )

    # Append public repo warning if applicable
    if public_repo?
      prompt += "\n\n#{public_repo_warning}"
    end

    prompt
  end

  private

  def build_context(comment_type, comment_data)
    context_parts = []

    if comment_type == "review"
      # For inline review comments, include the code context
      path = comment_data["path"]
      line = comment_data["line"]
      diff_hunk = comment_data["diff_hunk"]

      context_parts << "**File:** `#{path}`"
      context_parts << "**Line:** #{line}" if line
      context_parts << "**Code context (diff hunk):**\n```diff\n#{diff_hunk}\n```" if diff_hunk.present?

      # Fetch thread context if this is a reply or has replies
      thread_context = fetch_thread_context(comment_data)
      context_parts << thread_context if thread_context.present?
    else
      # For PR-level comments, fetch thread context
      thread_context = fetch_pr_comment_thread_context(comment_data)
      context_parts << thread_context if thread_context.present?
    end

    context_parts.join("\n\n")
  end

  def fetch_thread_context(comment_data)
    # For review comments that are part of a thread
    in_reply_to_id = comment_data["in_reply_to_id"]
    return nil unless in_reply_to_id

    # Find parent and sibling comments in the same thread
    pr_url = comment_info[:pr_url]
    all_review_comments = session.custom_metadata&.dig("github_comments", pr_url, "review_comments") || []

    # Find comments in the same thread (same in_reply_to_id or is the parent)
    thread_comments = all_review_comments.select do |c|
      c["id"] == in_reply_to_id ||
      c["in_reply_to_id"] == in_reply_to_id ||
      c["in_reply_to_id"] == comment_data["id"]
    end

    return nil if thread_comments.empty?

    thread_text = thread_comments
      .sort_by { |c| c["created_at"] }
      .map { |c| "**#{c['author']}:** #{c['body']}" }
      .join("\n\n")

    "**Previous comments in this thread:**\n#{thread_text}"
  end

  def fetch_pr_comment_thread_context(comment_data)
    # For PR-level comments, include ALL previous comments in the conversation
    # (since they form a single thread from the PR description)
    pr_url = comment_info[:pr_url]
    all_pr_comments = session.custom_metadata&.dig("github_comments", pr_url, "pr_comments") || []

    # Get all comments before this one
    comment_time = comment_data["created_at"]
    previous_comments = all_pr_comments
      .select { |c| c["created_at"] < comment_time && c["id"] != comment_data["id"] }
      .sort_by { |c| c["created_at"] }

    return nil if previous_comments.empty?

    thread_text = previous_comments
      .map { |c| "**#{c['author']}:** #{c['body']}" }
      .join("\n\n")

    "**Previous comments on this PR:**\n#{thread_text}"
  end

  def build_prompt(body:, author:, comment_url:, comment_type:, context:, pr_url:)
    comment_type_label = comment_type == "review" ? "inline review comment" : "PR comment"

    prompt_parts = []

    # Header with source info
    prompt_parts << "## GitHub Comment Response Required"
    prompt_parts << ""
    prompt_parts << "**User:** #{author}"
    prompt_parts << "**Comment type:** #{comment_type_label}"
    prompt_parts << "**Comment URL:** #{comment_url}"
    prompt_parts << "**PR:** #{pr_url}"
    prompt_parts << ""

    # The actual comment
    prompt_parts << "### User's Comment"
    prompt_parts << ""
    prompt_parts << "> #{body.gsub("\n", "\n> ")}"
    prompt_parts << ""

    # Context
    if context.present?
      prompt_parts << "### Context"
      prompt_parts << ""
      prompt_parts << context
      prompt_parts << ""
    end

    # Instructions - let the agent determine intent
    prompt_parts << "### Instructions"
    prompt_parts << ""
    prompt_parts << "Read the user's comment carefully and determine what they're asking for:"
    prompt_parts << ""
    prompt_parts << "**If the user is asking a question** (seeking clarification, explanation, or understanding):"
    prompt_parts << "- Analyze the question and formulate a helpful answer"
    prompt_parts << "- Reply to the comment on GitHub with your response"
    prompt_parts << "- Do NOT make code changes unless explicitly requested"
    prompt_parts << ""
    prompt_parts << "**If the user is requesting a code change** (asking you to fix, modify, add, or remove something):"
    prompt_parts << "- Make the requested changes in the codebase"
    prompt_parts << "- Create a **single commit** with a clear message describing the change"
    prompt_parts << "- Push the commit to the PR branch"
    prompt_parts << "- Reply to the comment on GitHub including a link to the commit so the user can review the diff"
    prompt_parts << "- Commit URL format: `https://github.com/OWNER/REPO/commit/COMMIT_SHA`"
    prompt_parts << ""
    prompt_parts << "**All GitHub responses must be prefixed with `[CC Says]`** (e.g., `[CC Says] Done! I've made the following change...`)"
    prompt_parts << ""

    # Response format based on comment type
    prompt_parts << "### Response Format"
    prompt_parts << ""

    if comment_type == "review"
      prompt_parts << "For inline review comments, reply in the same thread using:"
      prompt_parts << "```bash"
      prompt_parts << "gh api repos/OWNER/REPO/pulls/PR_NUMBER/comments \\"
      prompt_parts << "  -f body='[CC Says] Your response here' \\"
      prompt_parts << "  -f commit_id='COMMIT_SHA' \\"
      prompt_parts << "  -f path='FILE_PATH' \\"
      prompt_parts << "  -f line=LINE_NUMBER \\"
      prompt_parts << "  -f in_reply_to=#{comment_data_id}"
      prompt_parts << "```"
    else
      prompt_parts << "For PR-level comments, use:"
      prompt_parts << "```bash"
      prompt_parts << "gh pr comment #{comment_info[:pr_number]} --repo #{comment_info[:owner]}/#{comment_info[:repo]} --body '[CC Says] Your response here'"
      prompt_parts << "```"
    end

    prompt_parts.join("\n")
  end

  def comment_data_id
    comment_info[:data]["id"]
  end

  # Trusted owners whose public repositories don't require human approval
  # These are organizations/users that we control, so we trust agent actions on them
  TRUSTED_OWNERS = %w[pulsemcp tadasant].freeze

  # Check if the repository requires the public repo warning
  # Uses the GitHub API to fetch repository visibility
  #
  # Returns false (no warning needed) if:
  # - The repository is private
  # - The repository is owned by a trusted owner (pulsemcp, tadasant)
  # - Owner or repo is missing/blank
  #
  # Returns true (warning needed) if:
  # - The repository is public AND not owned by a trusted owner
  # - API call fails (err on the side of caution)
  def public_repo?
    owner = comment_info[:owner]
    repo = comment_info[:repo]
    return false if owner.blank? || repo.blank?

    # Trust our own repos - treat them like private repos (no warning needed)
    return false if TRUSTED_OWNERS.include?(owner.downcase)

    # Check cache first to avoid repeated API calls
    @repo_visibility_cache ||= {}
    cache_key = "#{owner}/#{repo}"
    return @repo_visibility_cache[cache_key] if @repo_visibility_cache.key?(cache_key)

    command = [ "gh", "api", "repos/#{owner}/#{repo}", "--jq", ".private" ]
    stdout, stderr, status = Open3.capture3(*command)

    if status.success?
      is_private = stdout.strip == "true"
      @repo_visibility_cache[cache_key] = !is_private
      !is_private
    else
      Rails.logger.warn "[GithubCommentPromptBuilder] Failed to check repo visibility for #{owner}/#{repo}: #{stderr}"
      # Default to true (treat as public) if API fails - better to require approval than risk public changes
      @repo_visibility_cache[cache_key] = true
      true
    end
  rescue StandardError => e
    Rails.logger.error "[GithubCommentPromptBuilder] Exception checking repo visibility: #{e.class} - #{e.message}"
    # Cache the result for consistency (cache_key may not be defined if error occurs early)
    if defined?(cache_key) && cache_key
      @repo_visibility_cache ||= {}
      @repo_visibility_cache[cache_key] = true
    end
    true
  end

  # Warning message to append to prompts for public repositories
  def public_repo_warning
    <<~WARNING.strip
      ---

      ⚠️ **PUBLIC REPOSITORY NOTICE**

      This is a public repository. You should NOT make any public-facing changes (emojis, comments, commits, pushes) without explicit review and approval by a human message (not this templated message).

      "Continue" is not sufficient approval - the human needs to directly respond to your proposed action with specific approval.

      **DO** still do all the exploring, analysis, and brainstorming you need to determine the right next action.
      **DO** propose your intended action in chat for human approval.
      **DO NOT** execute public-facing actions yourself until you receive explicit human approval.
    WARNING
  end
end
