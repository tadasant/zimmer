# Session State Machine

This document describes the state machine that manages the lifecycle of agent sessions in Agent Orchestrator.

## Overview

The session state machine is implemented using the AASM (Acts As State Machine) gem and is defined in `app/models/concerns/session_state_machine.rb`. It enforces valid state transitions and prevents invalid state changes that could lead to data corruption or orphaned processes.

## States

### waiting (initial state)
- **Description**: Session is queued but not yet running
- **Entry**: Session is created but the agent hasn't started execution yet
- **Exit**: Agent starts execution (→ running)

### running
- **Description**: Agent is actively executing
- **Entry**: Agent process has been spawned and is running
- **Exit**: Turn completes (→ needs_input), error occurs (→ failed)

### needs_input
- **Description**: Agent has paused and is waiting for user input
- **Entry**: Agent completes a turn and waits for follow-up prompt
- **Exit**: User sends follow-up prompt (→ running), error occurs (→ failed), user archives (→ archived)

### failed
- **Description**: Session encountered an error and cannot proceed
- **Entry**: Error during execution, transcript polling failure, process crash, or validation failure during resume (e.g., missing transcript cache files)
- **Exit**: User attempts restart (→ running), user archives (→ archived)

### archived (terminal)
- **Description**: Session has been archived by user
- **Entry**: User explicitly archives the session
- **Exit**: User unarchives to waiting/failed/needs_input (→ waiting, failed, or needs_input)
- **Side Effects**: Clone directory is cleaned up, running job is terminated

## Events and Transitions

### start
- **From**: waiting
- **To**: running
- **Guard**: `can_start?` - requires `git_root` to be present
- **Callback**: Logs state change
- **Triggered By**: AgentSessionJob when job begins execution

### pause
- **From**: running
- **To**: needs_input
- **Callback**: Logs state change, clears `running_job_id`, preserves clone for resume
- **Triggered By**: AgentSessionJob when agent completes a turn successfully, or SessionsController when user manually pauses

### resume
- **From**: needs_input, failed
- **To**: running
- **Guard**: `can_resume?` - requires `session_id` and existing clone directory
- **Callback**: Logs state change
- **Triggered By**: SessionsController when user sends follow-up prompt or restarts failed session

### fail
- **From**: running, needs_input
- **To**: failed
- **Callback**: Logs state change with failure reason, clears `running_job_id`, preserves debug info
- **Triggered By**: AgentSessionJob when error occurs, transcript polling fails repeatedly, or session validation fails during resume

### archive
- **From**: waiting, running, needs_input, failed
- **To**: archived
- **Callback**: Logs state change, clears `running_job_id`, cleans up clone directory
- **Triggered By**: SessionsController when user archives session (single or bulk)
- **Note**: Cannot archive from running state - must pause first

### unarchive_to_waiting
- **From**: archived
- **To**: waiting
- **Callback**: Logs state change
- **Triggered By**: SessionsController when user unarchives session and no completion logs exist

### unarchive_to_failed
- **From**: archived
- **To**: failed
- **Callback**: Logs state change
- **Triggered By**: SessionsController when user unarchives session and completion/failure logs exist

### unarchive_to_needs_input
- **From**: archived
- **To**: needs_input
- **Callback**: Logs state change
- **Triggered By**: SessionsController when user undoes archive within 5-second window

## State Machine Diagram

```
┌─────────┐
│ waiting │ (initial)
└────┬────┘
     │ start [can_start?]
     ▼
┌─────────┐
│ running │◄─────────────────────┐
└────┬────┘                      │
     │ pause                     │ resume [can_resume?]
     ▼                           │
┌──────────────┐                 │
│ needs_input  │─────────────────┤
└──────┬───────┘                 │
       │ fail                    │
       ▼                         │
┌─────────┐                      │
│ failed  │──────────────────────┘
└────┬────┘
     │ archive
     ▼
┌──────────┐
│ archived │ (terminal)
└──────────┘
```

## Guards

### can_start?
- **Condition**: `git_root.present?`
- **Purpose**: Ensures session has a repository to clone before starting

### can_resume?
- **Condition**: `session_id.present? && clone_exists?`
- **Purpose**: Ensures session has necessary data to resume (Claude CLI session ID and clone directory)

## Callbacks

### log_state_change(message)
- **Trigger**: After every state transition
- **Action**: Creates a log entry with the state change message
- **Error Handling**: Logs error but doesn't fail transition

### cleanup_running_job
- **Trigger**: After pause, fail, archive events
- **Action**: Clears `running_job_id` to indicate no job is processing the session
- **Error Handling**: Logs error but doesn't fail transition

### preserve_debug_info
- **Trigger**: After fail event
- **Action**: Ensures debug information (process_pid, clone_path, failure_reason) is preserved in metadata
- **Purpose**: Helps with debugging and potential recovery

### cleanup_clone
- **Trigger**: After archive event
- **Action**: Removes clone directory using GitCloneService
- **Error Handling**: Logs error but doesn't fail archival (cleanup failures shouldn't block archival)

## Usage Examples

### Starting a new session
```ruby
session = Session.create!(git_root: "https://github.com/user/repo.git", agent_runtime: "claude_code", branch: "main")
# Session initializes in :waiting state

session.start! if session.may_start?
# Session transitions to :running
```

### Pausing a running session
```ruby
session.pause! if session.may_pause?
# Session transitions to :needs_input
# running_job_id is cleared, clone is preserved
```

### Resuming with follow-up prompt
```ruby
session.resume! if session.may_resume?
# Session transitions from :needs_input to :running
```

### Handling failures
```ruby
session.update!(metadata: session.metadata.merge("failure_reason" => "network error"))
session.fail! if session.may_fail?
# Session transitions to :failed
# Debug info is preserved for recovery
```

### Archiving a session
```ruby
session.archive! if session.may_archive?
# Session transitions to :archived
# Clone directory is cleaned up
```

## Benefits

1. **Validation**: Guards prevent invalid transitions (e.g., can't start without git_root)
2. **Consistency**: Callbacks ensure side effects happen atomically with state changes
3. **Auditability**: All state changes are logged to the database
4. **Safety**: Prevents invalid state combinations that could lead to data corruption
5. **Clarity**: Makes valid state transitions explicit and self-documenting
6. **Recovery**: Preserves debug information and supports graceful failure handling

## Testing

Comprehensive tests for the state machine are in `test/models/session_state_machine_test.rb`, covering:
- All valid transitions
- All invalid transitions (should raise AASM::InvalidTransition)
- Guard conditions
- Callbacks and side effects
- Full lifecycle scenarios
