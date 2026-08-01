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
// `git -C /repo push`, `git --no-pager push`. Deliberately does not try to
// parse compound shell lines beyond finding the invocation.
const GIT_PUSH = /(^|[;&|(\s])git\s+(?:-{1,2}[^\s]+(?:\s+[^\s-][^\s]*)?\s+)*push(\s|$|;|&|\||\))/;

// A dry run pushes nothing, so there is no CI to wait for.
const DRY_RUN = /(^|\s)--dry-run(\s|$)/;

function isPushCommand(command) {
  if (typeof command !== "string" || command.length === 0) return false;
  return GIT_PUSH.test(command) && !DRY_RUN.test(command);
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

main().catch(() => {}).finally(() => process.exit(0));
