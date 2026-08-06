# Execution Layer

The Execution layer provides an abstraction for running AI agents (Claude Code or Codex, per `RuntimeRegistry`) against git repositories. It supports multiple execution providers with a unified interface.

## ⚠️ Nothing in `app/` calls this

Read this first, because it changes what every claim below is a claim *about*. The live path a
session actually takes is `AgentSessionJob` → `GitCloneService` → `ProcessLifecycleManager`. No
code under `app/` references `Execution::` at all. This layer is a parallel, unused implementation
of the same idea, kept because it is the sketch the remote-sandbox provider would grow from.

Two consequences worth carrying:

- A gap listed here is a gap in *this* layer, not necessarily in the code that runs your sessions.
  When both need a fix, the fix belongs in both — the pre-clone disk guard below is shared with
  `GitCloneService` for exactly that reason.
- `SessionExecutor` sets a finished session to `archived`, which is not what `AgentSessionJob`
  does (a live session that finishes a turn lands in `needs_input`). Do not read this layer's
  state handling as documentation of Zimmer's lifecycle;
  [`sessions/lifecycle`](https://docs.zimmer.tadasant.com/sessions/lifecycle/) is that.

## Overview

The execution layer implements a Strategy Pattern with pluggable providers that handle the actual execution environment setup and agent invocation. Currently supports:

- **Local Filesystem Provider**: Clones repos and runs the agent CLI locally using git clones
- **Remote Sandbox Provider**: Placeholder for future cloud-based sandboxed execution

## Architecture

```
Execution
├── Context           # Immutable value object with execution parameters
├── Result            # Standardized result from providers
├── SessionExecutor   # Main orchestrator for session execution
├── Providers
│   ├── Base          # Abstract provider interface
│   ├── LocalFilesystem  # Local execution with git clones
│   └── RemoteSandbox    # Future cloud sandbox (stub)
└── Support
    └── CommandBuilder      # Builds secure CLI commands
```

## Usage

### Basic Usage

```ruby
# Create a session
session = Session.create!(
  prompt: "Implement a new feature",
  agent_runtime: "claude_code",
  repository_url: "https://github.com/user/repo.git",
  branch: "main",
  execution_provider: "local_filesystem",
  mcp_servers: ["filesystem", "github"]
)

# Execute the session
result = Execution.execute(session)

if result.success?
  puts "Execution completed successfully"
  puts result.output
else
  puts "Execution failed: #{result.error}"
end
```

### Advanced Usage with Options

```ruby
session = Session.create!(...)

# Create executor with custom options
executor = Execution::SessionExecutor.new(session, options: {
  model: "claude-sonnet-4",
  timeout: 600,
  working_dir: "/custom/path"  # Optional override
})

# Execute full lifecycle: setup -> execute -> cleanup
result = executor.execute!

# Or run phases individually
setup_result = executor.setup
if setup_result.success?
  execute_result = executor.execute_only
  cleanup_result = executor.cleanup
end

# Check status
status = executor.status
# => { ready: true, provider: :local_filesystem, repo_path: "...", ... }
```

## Components

### Execution::Context

Immutable value object containing all execution parameters. Automatically populated from Session.

```ruby
context = Execution::Context.new(
  session: session,
  repository_url: "https://github.com/user/repo.git",  # Optional override
  branch: "feature-branch",                             # Optional override
  working_dir: "/tmp/custom",                           # Optional
  options: { timeout: 300 }                             # Optional
)

context.to_h  # Convert to hash
context.provider_type  # => :local_filesystem
```

**Validations:**
- `session` cannot be nil
- `prompt` cannot be empty
- `repository_url` cannot be empty
- `branch` cannot be empty

### Execution::Result

Standardized result object returned by all providers.

```ruby
# Create successful result
result = Execution::Result.success(
  output: "Task completed",
  metadata: { duration: 120 },
  provider_type: :local_filesystem
)

# Create failure result
result = Execution::Result.failure(
  error: "Setup failed",
  exit_status: 1,
  metadata: { step: "clone" },
  provider_type: :local_filesystem
)

# Check result
result.success?   # => true/false
result.failure?   # => true/false
result.output     # => output string
result.error      # => error message
result.metadata   # => additional data
result.to_h       # => hash representation
```

### Execution::SessionExecutor

Main orchestrator that manages provider lifecycle and logs results.

```ruby
executor = Execution::SessionExecutor.new(session, options: {})

# Full lifecycle execution
result = executor.execute!  # setup -> execute -> cleanup

# Individual phases
executor.setup          # Prepare environment
executor.execute_only   # Run agent (assumes setup done)
executor.cleanup        # Clean up resources

# Utilities
executor.status    # Check provider status
executor.info      # Get execution information
```

**Session Status Updates:**
- `running`: Execution started
- `archived`: Successful completion — `SessionExecutor#call` sets this directly
- `failed`: Execution or setup failed

Note that this is the execution layer's own state handling, not `AgentSessionJob`'s: a live session
that finishes a turn lands in `needs_input`, not `archived`. Nothing in `app/` references
`Execution::` today.

**Logging:**
Each phase (setup, execute, cleanup) creates a log entry in `session.logs` with full details.

### Providers

#### Base Provider

Abstract interface that all providers must implement:

```ruby
class MyProvider < Execution::Providers::Base
  def provider_type
    :my_provider
  end

  def setup
    # Prepare execution environment
    # Return Execution::Result
  end

  def execute
    # Run the agent
    # Return Execution::Result
  end

  def cleanup
    # Clean up resources
    # Return Execution::Result
  end

  def status
    # Optional: return status hash
    { ready: true, provider: provider_type }
  end
end
```

**Helper Methods:**
- `log_info(message)` - Log info message
- `log_error(message)` - Log error message
- `log_debug(message)` - Log debug message

#### Local Filesystem Provider

Executes Claude Code locally using git clones for isolation.

**How it works:**

1. **Setup Phase:**
   - Checks free space on the clones volume via `CloneDiskGuard` (see below), pruning orphaned
     clones if it is short and failing the setup with an actionable message if pruning is not enough
   - Creates a git clone at `{ClonesDirectory.base}/{repo-name}-{branch}-{timestamp}-{random}` for
     the specified branch
   - Generates `.mcp.json` config file in clone
   - Returns success result with paths

2. **Execute Phase:**
   - Builds Claude Code CLI command with proper escaping
   - Executes command in clone directory
   - Captures stdout/stderr
   - Returns result with output

3. **Cleanup Phase:**
   - Removes git clone
   - Removes `.mcp.json` config
   - Returns success result

**Directory Structure:**
```
~/.zimmer/       # Global location outside git working directory, on the durable volume
└── clones/
    └── {repo-name}-{branch}-{timestamp}-{random}/  # Isolated clone for session
        └── .mcp.json                               # MCP server configuration
```

**Configuration:**
- Clones are stored under `ClonesDirectory.base` — `~/.zimmer/clones/` by default, overridable
  with `AGENT_CLONES_DIR`. Resolve it through `ClonesDirectory`, never by rebuilding the path:
  the whole point of that module is that writers and the garbage collector cannot disagree about
  where clones live.
- There is no bare-repo cache. Each clone is a fresh `git clone --branch --single-branch` from the
  remote.

**Environment Variables:**
- `ANTHROPIC_API_KEY`: Claude API key (required)
- `CLONE_SIZING_TIMEOUT_SECONDS`: wall-clock cap for the disk guard's `du` (default 5)

#### Disk guard (`CloneDiskGuard`)

Shared with `GitCloneService`, so both writers into the clones volume answer "is there room?" the
same way. Before a clone starts:

1. Derive a requirement. The size of the most recently written existing clone of the *same*
   repository × `SIZE_SAFETY_FACTOR` (2), clamped between `MINIMUM_FREE_BYTES` (2 GiB) and
   `MAXIMUM_REQUIRED_BYTES` (10 GiB). No prior clone, or a `du` that times out, falls back to the
   floor.
2. Compare against free space from `df -Pk`. **Fails open**: a volume whose free space cannot be
   determined permits the clone, because a broken measurement must never be the reason no session
   can start.
3. If short, call `OrphanCloneFilesystemCleanupJob.reclaim_space` — which prunes *only* clone
   directories with no owning session row at all, older than 2 hours, stopping as soon as the
   volume has room.
4. If still short, raise `CloneDiskGuard::InsufficientDiskSpaceError` naming the volume, the
   shortfall, and what to do. In `GitCloneService` that surfaces as
   `GitCloneService::InsufficientDiskSpaceError` (a `GitError` subclass, deliberately not
   classified transient); here it becomes a `Result.failure` from `setup`.

See [`operate/background-jobs`](https://docs.zimmer.tadasant.com/operate/background-jobs/) for the
pruning safety rules and why the age bar stops where it does.

#### Remote Sandbox Provider

Placeholder for future implementation. Currently returns "not implemented" errors.

**Planned Features:**
- API-based sandbox creation
- Remote code execution in isolated containers
- Streaming log support
- Timeout and cancellation
- Resource cleanup

### Support Utilities

#### CommandBuilder

Builds secure, properly-escaped Claude Code CLI commands.

```ruby
builder = Execution::Support::CommandBuilder.new(
  prompt: "Your prompt",
  working_dir: "/path/to/clone",
  mcp_config_path: "/path/to/.mcp.json",
  options: {
    model: "claude-sonnet-4",
    timeout: 300,
    api_key: "sk-..."
  }
)

command = builder.build              # Shell-escaped string
array = builder.build_array          # Array for Process.spawn
env = builder.build_env              # Environment variables
opts = builder.spawn_options         # Process.spawn options
```

**Security:**
- Uses `Shellwords.escape` for all user input
- Validates all paths are absolute
- Validates timeout is positive
- Proper handling of special characters

## Database Schema

### Sessions Table

New columns added by execution layer:

```ruby
t.string :repository_url              # Git repository URL
t.string :branch, default: "main"     # Branch to checkout
t.string :execution_provider,         # Provider: "local_filesystem" (the only value Session accepts)
         default: "local_filesystem"
t.index :execution_provider
```

## Configuration

### Environment Variables

**Execution Layer:**
- `ANTHROPIC_API_KEY`: Required for Claude Code execution
- Clone directory is fixed at `~/.zimmer/clones/`
- Bare repos directory is `tmp/repos/` within the Rails app

**MCP Servers:**
- MCP server-specific vars (e.g., `GITHUB_PERSONAL_ACCESS_TOKEN`, `POSTGRES_CONNECTION_STRING`)

### MCP Servers

Configure available MCP servers in the top-level `mcp.json` (read through `AirCatalogService`, never parsed directly). See `https://docs.zimmer.tadasant.com/air/mcp-servers/` for the schema and `ServersConfig` service for details.

## Testing

```ruby
# Foundation
test/lib/execution/context_test.rb
test/lib/execution/result_test.rb

# Support utilities — shell-safety round-trips through a real shell parser
test/lib/execution/support/command_builder_test.rb

# Providers and orchestration
test/lib/execution/providers/base_test.rb
test/lib/execution/providers/local_filesystem_test.rb
test/lib/execution/session_executor_test.rb
test/lib/execution/provider_integration_test.rb

# The disk guard and the pruning it drives (both shared with the live clone path)
test/services/clone_disk_guard_test.rb
test/jobs/orphan_clone_filesystem_cleanup_job_test.rb
```

`local_filesystem_test.rb` clones from a git repository created in a temp directory and stubs
`ClonesDirectory.base` to a temp clones root, so it touches neither the network nor the real clones
volume. Keep it that way: a test that prunes or clones against `~/.zimmer/clones` is a test that can
delete a live session's working directory.

Run tests:
```bash
bin/rails test test/lib/execution/
```

## Future Enhancements

### Remote Sandbox Provider
- Implement HTTP client for sandbox API
- Add authentication/authorization
- Support streaming logs
- Add timeout and cancellation
- Implement resource quotas

### Local Filesystem Provider
- Add support for private repositories with SSH keys. Today a private repo is reached by rewriting
  an HTTPS GitHub remote to `https://TOKEN@github.com/...` with the PAT from credentials; an
  `ssh://` or `git@host:` remote gets no credential at all, and neither does a non-GitHub host.
- Cache dependencies (node_modules, etc.) across clones

### General
- Add support for multiple agent types beyond Claude Code
- Implement execution queuing and rate limiting
- Add metrics collection (execution time, success rate, etc.)
- Support for custom execution environments (Docker, etc.)
- Real-time progress streaming to frontend

## Troubleshooting

### Common Issues

**Error: "Repository clone failed"**
- Check repository URL is accessible
- Verify network connectivity
- For private repos, ensure authentication is configured

**Error: "claude-code command not found"**
- Ensure Claude Code CLI is installed: `npm install -g @anthropic/claude-code`
- Check `$PATH` includes npm global bin directory

**Error: "Required environment variable not set"**
- Check `ANTHROPIC_API_KEY` is set
- Verify MCP server environment variables (e.g., `GITHUB_PERSONAL_ACCESS_TOKEN`)
- See the top-level `mcp.json` for required vars per server

**Error: "Clone already exists"**
- Clone names carry a timestamp and 4 random bytes, so a collision means the *same provider
  instance* is being set up twice; `create_clone` removes the previous directory and re-clones.
- To release a specific session's clone: `Execution::SessionExecutor.new(session).cleanup`.

**Error: "Not enough disk space to clone into ..."**
- This is `CloneDiskGuard` refusing *before* any bytes are written, and it has already tried
  pruning. The message carries the volume, the free/required figures, and how much pruning
  reclaimed.
- Nothing here should be remedied with `rm -rf ~/.zimmer/clones/*`. That directory holds live
  sessions' working directories — the uncommitted work of anything currently running — and there
  is no remote to re-fetch it from. If pruning could not free the space, the volume is full of
  clones that *belong* to sessions: archive the sessions that no longer need theirs (which routes
  them through the trash pipeline), or grow the volume.
- `bin/rails runner 'OrphanCloneFilesystemCleanupJob.perform_now'` forces the scheduled sweep,
  which only ever touches directories with no owning session row.

## License

Part of the Zimmer application.
