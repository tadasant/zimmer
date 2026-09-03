// Git Push CI Reminder — an AIR hook body.
//
// Runs after the shell tool, on whichever runtime is executing the session. When
// the command that just ran was a `git push`, it injects a short reminder that
// pushing is not finishing: CI has to be confirmed green before the work is
// handed back. Anything else is a no-op.
//
// AIR is vendor-neutral, and this body is too. Two runtimes execute it today and
// they disagree about both halves of the contract:
//
//   | Runtime                        | stdin payload                          | how context reaches the model |
//   | ------------------------------ | -------------------------------------- | ----------------------------- |
//   | Claude Code (PostToolUse)      | `{tool_name, tool_input, tool_response}` | `hookSpecificOutput.additionalContext` |
//   | Pi via `@tadasant/pi-hooks`    | `{event, toolName, input, content}`      | `{"content": ...}`, which REPLACES the tool result |
//
// So the script reads either shape and answers in the matching dialect. Pi's
// `content` replaces rather than appends, which is why the Pi branch echoes the
// original tool output back with the reminder after it — dropping it would hide
// the command's real result from the model.
//
// Contract, on both runtimes:
//   - stdin  : one JSON object describing the tool call that just completed
//   - stdout : either nothing, or the runtime's own context-injection object
//   - exit   : always 0 — a hook must never fail the tool call it observes.
//
// Invoked as `node ./git-push-ci-reminder.mjs`. AIR's Claude adapter rewrites that
// relative path to "$CLAUDE_PROJECT_DIR/.claude/hooks/<id>/..." at install time;
// `@tadasant/pi-hooks` runs the command from the hook's own directory. Either way
// it resolves regardless of the agent's cwd.

const REMINDER = [
  "A git push just ran. Pushing is not the same as finishing:",
  "confirm CI before you report the work as done.",
  "",
  "- Use the `wait-for-ci` skill to block until CI passes or fails.",
  "- If CI fails, fix it and push again — do not hand back a red branch.",
  "- Only after CI is green should the PR be described as ready.",
].join("\n");

// Matches a push subcommand with any leading git options — `git push`,
// `git -C /repo push`, `git --no-pager push`. Deliberately does not try to parse
// compound shell lines beyond finding the invocation, and it does not track
// quoting: `echo "git push"` matches and `bash -c "git push"` does not. Both are
// acceptable, because the worst a false positive costs is one extra paragraph of
// context.
const GIT_PUSH = /(^|[;&|(\s])git\s+(?:-{1,2}[^\s]+(?:\s+[^\s-][^\s]*)?\s+)*push(\s|$|;|&|\||\))/;

// A dry run pushes nothing, so there is no CI to wait for. Tested against the
// push invocation's own arguments rather than the whole command line, so an
// unrelated `--dry-run` later in a compound command cannot suppress the reminder
// for a push that really happened.
const DRY_RUN = /(^|\s)(--dry-run|-n)(\s|$)/;

// Everything from the matched `push` to the end of that command — i.e. up to the
// next shell separator.
const PUSH_ARGS = /[;&|)]/;

// The shell tool's name differs per runtime: Claude Code calls it `Bash`, Pi calls
// it `bash`. Compared case-insensitively rather than enumerated, so a runtime that
// spells it `BASH` still matches.
const SHELL_TOOL = "bash";

function isPushCommand(command) {
  if (typeof command !== "string" || command.length === 0) return false;

  const match = GIT_PUSH.exec(command);
  if (!match) return false;

  const afterPush = command.slice(match.index + match[0].length);
  const separator = afterPush.search(PUSH_ARGS);
  const args = separator === -1 ? afterPush : afterPush.slice(0, separator);

  return !DRY_RUN.test(args);
}

/**
 * Normalize either runtime's payload into { runtime, toolName, command, output }.
 *
 * `PI_HOOK=1` is set by @tadasant/pi-hooks on every hook process, so the runtime is
 * read from the environment rather than inferred from which keys happen to be
 * present — a payload that grows a field should not silently change dialect.
 */
function normalize(payload) {
  if (process.env.PI_HOOK === "1") {
    return {
      runtime: "pi",
      toolName: payload?.toolName,
      command: payload?.input?.command,
      output: typeof payload?.content === "string" ? payload.content : "",
    };
  }
  return {
    runtime: "claude",
    toolName: payload?.tool_name,
    command: payload?.tool_input?.command,
    output: "",
  };
}

function render({ runtime, output }) {
  if (runtime === "pi") {
    // pi-hooks' `content` control REPLACES the tool result the model will read, so
    // the original output has to be carried through explicitly.
    return { content: output ? `${output}\n\n${REMINDER}` : REMINDER };
  }
  return {
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: REMINDER,
    },
  };
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

async function main() {
  let payload;
  try {
    payload = JSON.parse(await readStdin());
  } catch {
    // Malformed or empty input: stay quiet rather than spamming the transcript.
    return;
  }

  const event = normalize(payload);
  if (String(event.toolName ?? "").toLowerCase() !== SHELL_TOOL) return;
  if (!isPushCommand(event.command)) return;

  process.stdout.write(`${JSON.stringify(render(event))}\n`);
}

// No process.exit(): stdout is a pipe under both runtimes, writes to it are
// asynchronous, and exiting does not flush them. Once main() settles there is
// nothing left on the event loop, so Node exits 0 on its own after the payload
// has actually been written.
main().catch(() => {});
