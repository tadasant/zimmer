// Git Push CI Reminder — an AIR hook body.
//
// Runs as a Claude Code PostToolUse hook on the Bash tool (see HOOK.json). When
// the command that just ran was a `git push`, it injects a short reminder that
// pushing is not finishing: CI has to be confirmed green before the work is
// handed back. Anything else is a no-op.
//
// Contract with the runtime:
//   - stdin  : one JSON object (tool_name, tool_input, tool_response, ...)
//   - stdout : either nothing, or a PostToolUse hook result carrying
//              `additionalContext` for the agent to read
//   - exit   : always 0 — a hook must never fail the tool call it observes.
//
// Invoked as `node ./git-push-ci-reminder.mjs`; AIR's Claude adapter rewrites
// that relative path to "$CLAUDE_PROJECT_DIR/.claude/hooks/<id>/..." at install
// time, so it resolves regardless of the agent's cwd.

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

function isPushCommand(command) {
  if (typeof command !== "string" || command.length === 0) return false;

  const match = GIT_PUSH.exec(command);
  if (!match) return false;

  const afterPush = command.slice(match.index + match[0].length);
  const separator = afterPush.search(PUSH_ARGS);
  const args = separator === -1 ? afterPush : afterPush.slice(0, separator);

  return !DRY_RUN.test(args);
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

  if (payload?.tool_name !== "Bash") return;
  if (!isPushCommand(payload?.tool_input?.command)) return;

  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: REMINDER,
      },
    }) + "\n",
  );
}

// No process.exit(): stdout is a pipe under Claude Code, writes to it are
// asynchronous, and exiting does not flush them. Once main() settles there is
// nothing left on the event loop, so Node exits 0 on its own after the payload
// has actually been written.
main().catch(() => {});
