# frozen_string_literal: true

# Finds the directories inside a session clone that encode the clone's own
# absolute path, and therefore cannot be carried into a clone at a different
# path.
#
# Background (zimmer#671):
#   Zimmer copies a clone to a new directory in two places — `clones:relocate`
#   moves a clone to a new base, and `ForkSessionService` gives a fork a copy of
#   its source tree. Both rewrite the *session's* path-bearing state in lockstep
#   with the copy. Neither rewrites anything inside the copied tree, and a Python
#   virtualenv is not relocatable: every console script in `<venv>/bin` opens with
#   a shebang naming the interpreter by absolute path.
#
#     $ head -1 .venv/bin/pytest
#     #!/home/rails/.zimmer/clones/<THE-OLD-CLONE>/.venv/bin/python
#
#   The `.pth` files for editable installs are written relative to the venv, so
#   they follow the copy and point at the new clone. That is what makes the
#   failure so hard to read: `uv run python -c "import pkg; print(pkg.__file__)"`
#   reports the new clone and looks perfectly healthy, while `uv run pytest`
#   execs the shim, lands on the *old* clone's interpreter, and imports the *old*
#   clone's sources. It surfaces as an ImportError naming a symbol that plainly
#   exists in the file the error points at — because the path in the error is a
#   different checkout of the same repository.
#
#   The property that makes it worth a guard rather than a docs note is that it
#   is silently *stale* rather than broken. Had the two checkouts not diverged,
#   the suite would have gone green against the wrong tree.
#
# What this does about it: name the directory so the copy can leave it behind.
# A clone that arrives without a virtualenv fails loudly and cheaply — `uv sync`
# against a warm cache rebuilds it in seconds — where a clone that arrives with
# a stale one fails silently or not at all.
#
# Nothing here deletes anything. Detection reads the source tree and returns
# patterns; the copy applies them while writing the destination. That is
# deliberate, and it is the whole safety argument: the relocation path runs
# against LIVE sessions by design ("Copy (never move) so a live session's cwd is
# never pulled out from under it"), so a remedy that removed a directory could
# pull a working tree out from under a running agent. Skipping a directory
# during a copy cannot.
class NonRelocatableClonePaths
  # What makes a directory a virtualenv, per PEP 405: the interpreter treats a
  # directory containing this file as an environment root. Matching on the marker
  # rather than on a name (`.venv`, `venv`, `env`, `.direnv/python-3.13`) both
  # over- and under-matches less: a source directory that merely happens to be
  # called `venv` is kept, and an environment under any name is found.
  VIRTUALENV_MARKER = "pyvenv.cfg"

  # fnmatch metacharacters, escaped so a detected path is matched literally.
  # `copy_pruned` matches without FNM_NOESCAPE, so a backslash escape is honored.
  FNMATCH_METACHARACTERS = /([*?\[\]{}\\])/

  class << self
    # The non-relocatable directories inside a clone.
    #
    # @param clone_path [String] the root of the clone about to be copied
    # @param file_system [FileSystemAdapter, nil] defaults to the real one
    # @return [Array<String>] paths relative to the clone root, sorted and
    #   unique. Never includes the clone root itself.
    def detect(clone_path, file_system: nil)
      return [] if clone_path.blank?

      fs = file_system || RealFileSystemAdapter.new
      root = File.expand_path(clone_path)
      return [] unless fs.directory?(root)

      virtualenv_roots(fs, root)
        .filter_map { |dir| relative_to(dir, root) }
        .uniq
        .sort
    rescue StandardError => e
      # Detection is a refinement of a copy that has to happen either way. A tree
      # this cannot read is copied whole — the pre-existing behaviour — rather
      # than failing the fork or the relocation outright.
      Rails.logger.warn("[NonRelocatableClonePaths] Could not scan #{clone_path}: #{e.message}")
      []
    end

    # Turn detected relative paths into `exclude:` patterns for
    # FileSystemAdapter#cp_r, which matches each entry's path relative to the
    # copy root with fnmatch.
    #
    # @param relative_paths [Array<String>]
    # @return [Array<String>]
    def to_patterns(relative_paths)
      Array(relative_paths).map { |path| path.gsub(FNMATCH_METACHARACTERS, '\\\\\1') }
    end

    private

    # Every directory under the clone that holds a `pyvenv.cfg`.
    #
    # FNM_DOTMATCH is load-bearing: without it `**/` never descends into a
    # hidden directory, and the environment is called `.venv` far more often
    # than anything else, so both `.venv/pyvenv.cfg` and
    # `packages/api/.venv/pyvenv.cfg` would be invisible.
    def virtualenv_roots(fs, root)
      fs.glob(File.join(root, "**", VIRTUALENV_MARKER), flags: File::FNM_DOTMATCH)
        .map { |marker| File.dirname(marker) }
    end

    # nil for anything that is not strictly below the root — including the root
    # itself, which a `pyvenv.cfg` written directly into the clone would
    # otherwise name. Excluding "" would prune the entire copy.
    def relative_to(dir, root)
      expanded = File.expand_path(dir)
      return nil unless expanded.start_with?("#{root}#{File::SEPARATOR}")

      relative = expanded.delete_prefix("#{root}#{File::SEPARATOR}")
      relative.presence
    end
  end
end
