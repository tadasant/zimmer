# Execution Layer

The Execution layer provides an abstraction for running AI agents (currently Claude Code) against git repositories. It supports multiple execution providers with a unified interface.

## Overview

The execution layer implements a Strategy Pattern with pluggable providers that handle the actual execution environment setup and agent invocation. Currently supports:

- **Local Filesystem Provider**: Clones repos and runs Claude Code CLI locally using git clones
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
- `archived`: Successful completion
- `failed`: Execution or setup failed

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
   - Clones repository to `tmp/repos/{repo-name}` (bare clone)
   - Creates git clone at `~/.agent-orchestrator/clones/session-{id}` for the specified branch
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
~/.agent-orchestrator/       # Global location outside git working directory
└── clones/
    └── {repo-name}-{branch}-{timestamp}-{random}/  # Isolated clone for session
        └── .mcp.json                               # MCP server configuration

tmp/repos/                   # Within Rails app directory
└── repo-name/               # Bare git repository (reused across sessions)
```

**Configuration:**
- Clones are stored in `~/.agent-orchestrator/clones/` (global, outside repo)
- Bare repos are stored in `tmp/repos/` (within Rails app)

**Environment Variables:**
- `ANTHROPIC_API_KEY`: Claude API key (required)

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
t.string :execution_provider,         # Provider: "local_filesystem" or "remote_sandbox"
         default: "local_filesystem"
t.index :execution_provider
```

## Configuration

### Environment Variables

**Execution Layer:**
- `ANTHROPIC_API_KEY`: Required for Claude Code execution
- Clone directory is fixed at `~/.agent-orchestrator/clones/`
- Bare repos directory is `tmp/repos/` within the Rails app

**MCP Servers:**
- MCP server-specific vars (e.g., `GITHUB_PERSONAL_ACCESS_TOKEN`, `POSTGRES_CONNECTION_STRING`)

### MCP Servers

Configure available MCP servers in `config/mcp.json`. See `https://docs.zimmer.tadasant.com/air/mcp-servers/` for the schema and `ServersConfig` service for details.

## Testing

Comprehensive test coverage includes:

```ruby
# Foundation
test/lib/execution/context_test.rb
test/lib/execution/result_test.rb

# Support utilities
test/lib/execution/support/command_builder_test.rb

# Integration tests would go here (not yet implemented):
# test/lib/execution/providers/local_filesystem_test.rb
# test/lib/execution/session_executor_test.rb
```

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
- Add disk space checks before cloning
- Implement clone pruning for old sessions
- Add support for private repositories with SSH keys
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
- See `config/mcp.json` for required vars per server

**Error: "Clone already exists"**
- Previous cleanup may have failed
- Manually remove: `rm -rf ~/.agent-orchestrator/clones/{clone-dir}`
- Run cleanup: `Execution::SessionExecutor.new(session).cleanup`

**Disk Space Issues**
- Check available space in `~/.agent-orchestrator/clones/` and `tmp/repos/`
- Clean up old clones: `rm -rf ~/.agent-orchestrator/clones/*` (be careful in production)

## License

Part of the Zimmer application.
