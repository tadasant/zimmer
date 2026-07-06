# Testing Philosophy

This document defines our testing philosophy and engineering approach. It should be read before building new features or making changes that involve tests.

## Core Principle: Design for Testability

When starting development, **work backwards from how you will verify correctness**. Before writing implementation code, ask yourself:

- How will I prove this works?
- What are the boundaries of this system?
- Where does external input enter, and where do external effects occur?

Design your code so that testing is straightforward:
- Keep external dependencies at the edges of your system
- Make dependencies injectable where it matters
- Avoid mixing business logic with I/O operations

This approach results in code that is both easier to test AND easier to maintain.

## Following Precedent

Follow existing patterns in the codebase by default. Before introducing new testing paradigms:

1. Search for similar tests to understand established patterns
2. If existing patterns conflict with this document (and were written before January 25, 2026), propose a new approach
3. **Check with the user before deviating from existing patterns** - don't unilaterally change paradigms

## Test Layers

### Unit Tests (Model Tests)

**Purpose**: Double-check correctness of non-trivial logic.

**When to write them**:
- Business logic that has meaningful branching or computation
- Model validations and custom methods with logic
- State machine transitions (AASM)

**When NOT to write them**:
- Simple configuration that is declarative and obviously correct at a glance
- Boilerplate where the test would be more complex than the code
- Simple getters/setters with no logic

**Example of test noise to avoid**:
```ruby
# The code (obviously correct):
validates :prompt, presence: true

# DON'T write tests like this - the code is clearer than the test:
test "requires prompt" do
  session = Session.new(prompt: nil)
  assert_not session.valid?
  assert_includes session.errors[:prompt], "can't be blank"
end
```

Unit tests should make you more confident about tricky logic, not restate obvious declarations.

### Controller / Job / Service Tests

**Purpose**: Verify backend logic that stretches across modules.

**When to write them**: Liberally. These tests are:
- Fast to run
- Cover complex territory (request → response cycle, job execution, service orchestration)
- Great for testing integrations between models, services, and external interfaces

Don't hold back on writing these tests. A comprehensive controller test suite catches many bugs that unit tests miss without the overhead of system tests.

**What to test**:
- Happy paths with expected inputs and outputs
- Authorization and authentication flows
- Error handling and edge cases
- Side effects (jobs enqueued, records created, broadcasts sent)
- Turbo Stream responses and partials

### System Tests

**Purpose**: Verify that JavaScript-powered UI flows align with backend behavior.

**When to write them**:
- User interactions that involve JavaScript/Stimulus controllers
- Multi-step workflows where UI state must sync with server state (e.g., Turbo Streams, real-time updates)
- Features where UI behavior is the primary concern

**When NOT to write them**:
- Pure backend functionality (use controller tests instead)
- Simple forms without JavaScript interactions
- CRUD operations that controller tests already cover

**Critical considerations**:

1. **System tests are slow**: They run mostly sequentially and involve browser automation overhead.

2. **System tests are flaky**: Timing issues, JavaScript loading, and network conditions can cause intermittent failures.

3. **Consolidate related assertions**: Instead of writing 10 separate tests for 10 interrelated features, combine them into a "happy path" test with sequential assertions:

```ruby
# PREFERRED: One comprehensive test covering a workflow
test "user creates session, views transcript, and archives" do
  visit sessions_path
  click_link "New Session"

  fill_in "Prompt", with: "Fix the login bug"
  click_button "Create"
  assert_text "Session created"

  click_link "View Transcript"
  assert_text "Fix the login bug"

  click_button "Archive"
  assert_text "Archived"
end

# AVOID: 10 separate tests that each navigate through similar setup
test "user can create session" do ... end
test "user can view transcript" do ... end
test "user can archive session" do ... end
```

This approach reduces total test runtime significantly while still verifying all functionality.

### Contract Tests

**Purpose**: Enforce structural guarantees across test/production boundaries.

This codebase has contract tests in `test/contracts/` that verify:
- Production code never references test-only classes (e.g., `MockProcessManager`)
- ENV variables use explicit `== "true"` comparison instead of truthiness
- Job method signatures match expectations
- Broadcast method contracts are honored
- View rendering contracts are respected
- Supervisor test coverage requirements are met

Contract tests are a first-class citizen of the test suite. When adding new mock classes or changing public interfaces, check whether contract tests need updating.

### Integration Tests

**Purpose**: Verify multi-step backend workflows that span multiple models, services, and jobs.

The `test/integration/` directory contains tests for end-to-end backend flows like session lifecycle, error recovery, and transcript polling. These use `IntegrationTestCase` which disables transactional fixtures and manages cleanup manually.

Use integration tests when a workflow involves multiple components interacting (e.g., session creation → job enqueuing → state transitions → log creation) and controller tests alone would not cover the full sequence.

## The Mocking Policy

**This is the most important section in this document.** Violations of this policy have directly caused production bugs that tests failed to catch. See `test/contracts/production_parity_test.rb` for documented incidents where test/production parity mismatches led to real failures.

### Never Mock Internal Systems

**NEVER use mocks/stubs for code we control.** This includes:
- Model methods and ActiveRecord persistence (`save!`, `update!`, `destroy`)
- Service objects and their methods
- Job methods (including private helper methods on the job under test)
- Controller methods and before_action filters
- Helpers and utilities
- Any class or method in our codebase

Instead, use real objects:
- Use fixtures to create test data
- Call actual methods and verify actual results
- Let integration naturally happen
- To trigger error paths, set up data that causes a real error (e.g., invalid params, constraint violations) rather than stubbing a method to raise

**Why?** Mocking internal code creates tests that verify mocks, not actual behavior. When internal implementations change, mock-heavy tests can pass while real code breaks.

### Common Violations and How to Fix Them

These are illustrative patterns to recognize and avoid.

#### Violation 1: Stubbing a job's own methods

```ruby
# BAD: Stubs the method under test -- hides bugs in the real method
ClaudeCliAdapter.any_instance.stubs(:build_command).returns(["echo", "hello"])

# REAL BUG THIS COULD HIDE: The method might construct an invalid command
# array, pass wrong environment variables, or miss a required flag.
# Tests pass because the real method never runs.
```

**Fix:** If the method has hardcoded paths or test-unfriendly dependencies, make those injectable rather than stubbing the entire method:

```ruby
# GOOD: Use dependency injection (this codebase already does this well)
# The job accepts a claude_cli_adapter parameter, so inject MockClaudeCliAdapter
# instead of stubbing AgentSessionJob's internal methods.
job = AgentSessionJob.new
job.perform(session.id)
# MockClaudeCliAdapter handles the external boundary
```

#### Violation 2: Stubbing ActiveRecord callbacks to avoid side effects

```ruby
# BAD: Stubs away model callbacks to prevent broadcasts
Log.any_instance.stubs(:broadcast_append_to_timeline)
Session.any_instance.stubs(:broadcast_status_change)

# This suppresses after_create_commit hooks entirely. If the broadcast
# method signature changes or the callback is removed, these tests
# still pass while the UI breaks silently.
```

**Fix:** If broadcasts cause test issues, stub at the transport boundary (ActionCable/Turbo channel) rather than on the model:

```ruby
# GOOD: Stub the transport layer, not the model method
Turbo::StreamsChannel.stubs(:broadcast_append_to)
Turbo::StreamsChannel.stubs(:broadcast_replace_to)

# Now the model's broadcast methods still execute (catching signature bugs),
# but the actual WebSocket transport is silenced.
```

#### Violation 3: Stubbing internal validation or branching logic

```ruby
# BAD: Stubs away the validation logic that determines the code path
AgentSessionJob.any_instance.stubs(:validate_session_state).returns(true)

# If the validation logic has bugs or the state machine transitions
# are wrong, these tests will never catch it.
```

**Fix:** Set up test data that exercises the real validation:

```ruby
# GOOD: Create a session in the correct state so real validation passes
session = sessions(:waiting)
session.update!(status: "running", pid: 12345)
# The job's validation runs for real against properly set up data
```

#### Violation 4: Stubbing ActiveRecord methods to simulate errors

```ruby
# BAD: Stubs persistence to simulate a failure
Session.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid)

# BETTER: Set up data that causes a real validation error
session = Session.new(prompt: nil) # triggers real validation failure
```

### The Key Principle: Ask "What Am I Actually Testing?"

Before writing a stub, ask: **"If the stubbed method had a bug, would this test catch it?"**

If the answer is no, you're testing your stubs, not your code. The mock is a liability -- it creates false confidence.

**The only acceptable reason to stub** is to avoid crossing a system boundary (OS processes, external APIs, filesystem I/O, WebSocket transport). Everything else should run for real.

### Only Mock External Systems

**Mocks are EXCLUSIVELY for external systems:**
- OS process management (use `MockProcessManager`)
- Filesystem operations (use `MockFileSystemAdapter`)
- Claude CLI interactions (use `MockClaudeCliAdapter`)
- External HTTP calls (use `stub_request` / WebMock)
- Git clone operations (stub `GitCloneService`)
- ActionCable/Turbo transport layer (stub `Turbo::StreamsChannel`)

### The Dependency Injection Pattern

This codebase already follows a strong dependency injection pattern for external boundaries. This is the preferred approach.

```ruby
# GOOD: Services accept injected dependencies with nil defaults
class ProcessTerminationService
  def initialize(process_pid:, process_manager: nil, log_buffer: nil, session: nil)
    @process_pid = process_pid
    @process_manager = process_manager || SystemProcessManager.new
  end
end

# In tests, inject mock dependencies:
service = ProcessTerminationService.new(
  process_pid: 12345,
  process_manager: @mock_process_manager
)

# The service's business logic runs for real.
# Only the OS boundary (process signals) is mocked.
```

The adapter classes (`ClaudeCliAdapter`, `FileSystemAdapter`, `SystemProcessManager`) are intentionally thin wrappers around OS and external calls, designed to be the mock boundary. All business logic lives in the calling code, which is tested with real objects.

**Characteristics of a well-designed injectable boundary:**
- Minimal logic in the mocked layer (just a bridge to the OS/network call)
- All business logic lives in calling code (which we test with real objects)
- Easy to understand what the mock is simulating
- Changes to external systems only require updating one adapter
- Contract tests in `test/contracts/` enforce that mock classes stay out of production code

### Mock Infrastructure

The codebase provides purpose-built mock classes in `test/support/`:

| Mock Class | Replaces | Boundary |
|---|---|---|
| `MockProcessManager` | `SystemProcessManager` | OS process lifecycle (spawn, kill, wait) |
| `MockFileSystemAdapter` | `FileSystemAdapter` | Filesystem I/O (read, write, exists?) |
| `MockClaudeCliAdapter` | `ClaudeCliAdapter` | Claude CLI process execution |
| `MockRateLimitTracker` | `GlobalRateLimitTracker` | Rate limit state tracking |

`MockProcessManager` and `MockFileSystemAdapter` are injected via singleton replacement in `test/support/mock_helpers.rb`. `MockClaudeCliAdapter` and `MockRateLimitTracker` are injected via constructor parameters in individual tests. All mocks support hooks (e.g., `spawn_hook`, `wait_hook`) for fine-grained control over behavior in specific tests.

When adding a new external integration, follow the same pattern:
1. Create a thin adapter class for production
2. Create a corresponding mock in `test/support/`
3. Add a contract test in `test/contracts/production_parity_test.rb` to prevent the mock from leaking into production code

## PR Testing Requirements

### 1. Local Verification

Run targeted tests for your changes (see the [file → test mapping](../CLAUDE.md#local-testing-strategy) in CLAUDE.md):

```bash
# Run specific test file with timeout to prevent runaway output
timeout 60 bin/rails test test/services/my_service_test.rb
```

Always use `timeout` when running tests locally to prevent context overflow from crashes.

### 2. CI Verification

All tests must pass in CI before merge. Use the `wait-for-CI` skill to monitor.

### 3. PR Verification Section (Closed Loop)

**Every PR must include a "## Verification" section that documents how you closed the loop — what you actually did to confirm the change works.** This is NOT a TODO list for the reviewer. By the time you open the PR, verification should already be complete and every item should be checked off.

The purpose of this section is to give the reviewer confidence that the change was validated, not to assign them work. If you can't check a box, either do the verification first or explain why it wasn't possible.

**What to include (checked, with results):**
- `[x]` CI status — confirm you waited and it passed (e.g., "CI green — all 3 jobs pass")
- `[x]` Tests — what tests you added/ran and their results (e.g., "Ran cleanup_job_test.rb — 11/11 passed")
- `[x]` Self-review — "Reviewed PR diff for correctness and style"
- `[x]` Proof — concrete evidence that the change works (see below)

The key is **reporting results, not just actions**. "Added tests" is not enough — "Ran tests and 11/11 passed" closes the loop.

#### Proof: Evidence, Not Assertion

Beyond standard checks, the Verification section should include **proof** — concrete evidence that the change works. "Tested it and it works" is not proof. A screenshot, a test output, or a confirmation receipt IS proof.

**Proof types and when to use each:**

| Change Type | Proof Type | What to Include |
|-------------|-----------|---------|
| Backend/logic changes | E2E test report | Describe what you tested end-to-end and what happened |
| UI changes | Screenshot | **Required.** Include a screenshot showing the change works |
| External side effects | External confirmation | Show the confirmation email, API response, or receipt |
| Config/docs-only changes | Self-review | Proof may be as simple as confirming the content is accurate |

**UI changes MUST include screenshots.** If you changed something visual, show it. No exceptions.

Proof should be inline in the PR description:
- Screenshots as markdown images: `![description](url)`
- Test output as code blocks
- API responses or confirmations as quoted text or code blocks

**Example verification section with proof:**
````markdown
## Verification
- [x] Added `test/jobs/cleanup_job_test.rb` — ran locally, 4/4 new tests pass
- [x] CI green (all 3 jobs: brakeman, rubocop, tests)
- [x] Self-reviewed PR diff — no unintended changes, no debug code
- [x] E2E: created a session with TTL=30s, waited 60s, confirmed session was cleaned up in logs
````

**Example for a UI change:**
````markdown
## Verification
- [x] CI green (all 3 jobs)
- [x] Self-reviewed PR diff
- [x] Screenshot of updated settings page:
  ![settings page](https://github.com/user-attachments/assets/...)
````

**Example for external side effects:**
````markdown
## Verification
- [x] CI passes
- [x] Sent test webhook to partner endpoint, confirmed 200 response:
  ```json
  {"status": "ok", "event_id": "evt_abc123"}
  ```
````

**Anti-pattern — do NOT do this:**
```markdown
## Test plan
- [ ] CI passes
- [ ] Verify the feature works on staging
- [ ] Check that existing tests still pass
```


Unchecked boxes in a PR description are useless — they describe aspirational work that nobody will do. The agent should close the loop before handing the PR to a human.

## Quick Reference

| Scenario | Test Type | Notes |
|----------|-----------|-------|
| Model validation logic | Unit test | Only for non-trivial validations |
| State machine transitions | Unit test | AASM state changes |
| Complex business logic | Unit/Service test | Methods with branching, calculations |
| API endpoint | Controller test | Always |
| Background job | Job test | Always |
| Multi-step UI workflow | System test | Consolidate related steps |
| External service integration | Service test with mock | Use dependency injection pattern |
| Multi-step backend workflow | Integration test | Session lifecycle, error recovery |
| Simple CRUD | Controller test | Skip system tests unless JS-heavy |
| Mock/production boundary | Contract test | Prevent mock leakage |
