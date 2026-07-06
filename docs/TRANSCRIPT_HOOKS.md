# Transcript Hooks

Transcript hooks are a plugin system for analyzing agent session transcripts and extracting useful data into the session's `custom_metadata` field.

## Overview

When the `TranscriptPollerService` polls new messages from a session's transcript, it runs all registered transcript hooks. Each hook can analyze the transcript content and update the session's `custom_metadata` with extracted information.

## Built-in Hooks

### GithubPrUrlHook

Extracts GitHub Pull Request URLs from **tool result** content and stores them in `custom_metadata["github_pull_request_url"]`.

Note: Only URLs appearing in tool results (e.g., output from `gh pr create`) are extracted. PR URLs mentioned in assistant text are intentionally ignored to avoid false positives.

**Pattern matched**: `https://github.com/{owner}/{repo}/pull/{number}`

**Example**:
```ruby
session.custom_metadata
# => { "github_pull_request_url" => "https://github.com/owner/repo/pull/123" }
```

## Creating a New Hook

### Step 1: Create the Hook Class

Create a new file in `app/services/transcript_hooks/`:

```ruby
# app/services/transcript_hooks/my_hook.rb
class TranscriptHooks::MyHook < TranscriptHooks::BaseHook
  def call
    # Skip if we already have the data
    return if get_custom_metadata("my_key").present?

    # Extract data from transcript
    extracted_value = extract_from_transcript
    return unless extracted_value

    # Store in custom_metadata
    update_custom_metadata("my_key" => extracted_value)
    Rails.logger.info "[MyHook] Extracted value for session #{session.id}: #{extracted_value}"
  end

  private

  def extract_from_transcript
    # Use all_text_content helper for simple text searches
    match = all_text_content.match(/your pattern here/)
    match&.to_s
  end
end
```

### Step 2: Register the Hook

Add your hook to the initializer in `config/initializers/transcript_hooks.rb`:

```ruby
Rails.application.config.after_initialize do
  # Register built-in hooks
  TranscriptHooks::Registry.register_defaults!

  # Register custom hooks
  TranscriptHooks::Registry.register(TranscriptHooks::MyHook)
end
```

## BaseHook API

### Attributes

- `session` - The Session record being processed
- `transcript_content` - Raw JSONL transcript content (string)
- `new_messages` - Array of new message hashes since last poll

### Helper Methods

#### `update_custom_metadata(updates)`
Merges the provided hash into the session's `custom_metadata`.

```ruby
update_custom_metadata("key" => "value", "another_key" => 123)
```

#### `get_custom_metadata(key)`
Retrieves a value from the session's `custom_metadata`.

```ruby
value = get_custom_metadata("my_key")
```

#### `parsed_transcript`
Parses the JSONL transcript content into an array of message hashes.

```ruby
parsed_transcript.each do |message|
  type = message["type"]           # "user", "assistant", etc.
  content = message["message"]     # Message content hash
end
```

#### `all_text_content`
Extracts all text content from the transcript as a single string. Useful for simple pattern matching.

```ruby
if all_text_content.include?("important keyword")
  # Do something
end
```

#### `tool_result_content`
Extracts content from tool result messages only. Useful when you want to analyze command output specifically.

```ruby
# Only match patterns in tool results, not assistant text
match = tool_result_content.match(/https:\/\/example\.com\/\d+/)
```

## Hook Execution

Hooks are executed:
1. Only when new messages are broadcast (not on every poll)
2. Sequentially in registration order
3. With error isolation (one hook failing doesn't affect others)
4. After the transcript is saved to the database

## Testing Hooks

```ruby
# test/services/transcript_hooks/my_hook_test.rb
require "test_helper"

class TranscriptHooks::MyHookTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running_session)
    @transcript_content = <<~JSONL
      {"type":"user","message":{"content":"Hello"}}
      {"type":"assistant","message":{"content":"Here is your pattern"}}
    JSONL
  end

  test "extracts pattern from transcript" do
    hook = TranscriptHooks::MyHook.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_equal "expected_value", @session.custom_metadata["my_key"]
  end

  test "skips if pattern not found" do
    @transcript_content = '{"type":"user","message":{"content":"No pattern here"}}'

    hook = TranscriptHooks::MyHook.new(
      session: @session,
      transcript_content: @transcript_content,
      new_messages: []
    )

    hook.call

    @session.reload
    assert_nil @session.custom_metadata["my_key"]
  end
end
```

## Architecture

```
app/services/transcript_hooks/
├── base_hook.rb           # Base class with helper methods
├── registry.rb            # Hook registration management
├── executor.rb            # Runs all registered hooks
└── github_pr_url_hook.rb  # Built-in PR URL extraction hook

config/initializers/
└── transcript_hooks.rb    # Hook registration configuration
```

## Best Practices

1. **Idempotency**: Check if data already exists before extracting to avoid unnecessary updates
2. **Error Handling**: Let exceptions propagate - the executor handles them gracefully
3. **Performance**: Use `all_text_content` for simple searches, `parsed_transcript` for structured analysis
4. **Logging**: Log important extractions for debugging
5. **Testing**: Write comprehensive tests for your extraction logic
