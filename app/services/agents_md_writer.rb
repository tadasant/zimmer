# frozen_string_literal: true

# Writes the orchestrator system prompt to the working directory for runtimes
# that consume their instructions from a file rather than a CLI flag.
#
# Claude Code receives the orchestrator system prompt via `--append-system-prompt`
# at spawn time. Codex has no equivalent flag — it reads project instructions from
# `AGENTS.md` — so Zimmer writes the same orchestrator context (Zimmer operating
# principles + the Codex runtime contribution) into `AGENTS.md` during prepare.
#
# If the repo already ships an `AGENTS.md`, Zimmer's content is appended below a
# clearly delimited marker rather than overwriting it, so the repo's own project
# instructions are preserved (mirroring how Claude's `CLAUDE.md` and Zimmer's appended
# system prompt coexist).
#
# Skill/hook/plugin content does NOT flow through this writer — those reach Codex
# through their own native discovery surfaces (`.agents/skills/`, `.codex/`), wired
# by the AIR Codex adapter. This writer only delivers the system-prompt slice.
class AgentsMdWriter
  # Marks the start of Zimmer-managed content appended to a pre-existing AGENTS.md.
  AO_SECTION_MARKER = "<!-- BEGIN Zimmer context (managed by Zimmer) -->"

  attr_reader :session, :working_directory, :file_system

  # @param session [Session] the session being prepared
  # @param working_directory [String] the session's working directory
  # @param file_system [FileSystemAdapter] injectable file system (default: RealFileSystemAdapter)
  def initialize(session:, working_directory:, file_system: nil)
    @session = session
    @working_directory = working_directory
    @file_system = file_system || RealFileSystemAdapter.new
  end

  # The orchestrator system prompt for this session's runtime.
  def content
    OrchestratorSystemPromptBuilder.build(
      session: session,
      clone_path: working_directory,
      runtime: session.agent_runtime
    )
  end

  # Resolve the destination filename from the runtime's prompt contribution
  # (e.g. "AGENTS.md" for Codex). Falls back to "AGENTS.md" so the writer always
  # has a target when invoked for a file-delivery runtime.
  def filename
    RuntimePromptContribution.for(session.agent_runtime).system_prompt_filename || "AGENTS.md"
  end

  def target_path
    File.join(working_directory, filename)
  end

  # Write the orchestrator context to the target file. The Zimmer content is always
  # wrapped in AO_SECTION_MARKER so it can be detected on re-runs: appended below
  # a delimiter when the file already exists, written on its own otherwise. The
  # marker is the dedupe key, so it must be present even on a fresh write to keep
  # repeated prepares idempotent.
  def write!
    section = "#{AO_SECTION_MARKER}\n\n#{content}\n"
    path = target_path

    if file_system.exists?(path)
      existing = file_system.read(path).to_s
      return path if existing.include?(AO_SECTION_MARKER) # idempotent: don't double-append

      file_system.write(path, "#{existing.rstrip}\n\n#{section}")
    else
      file_system.write(path, section)
    end

    Rails.logger.info "[AgentsMdWriter] Wrote orchestrator context to #{path}"
    path
  end
end
