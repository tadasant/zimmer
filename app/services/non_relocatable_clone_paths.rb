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

  # Where a virtualenv keeps the console scripts that carry the absolute shebang
  # — POSIX and Windows layouts. Requiring one alongside the marker is what
  # separates an environment from a repository that merely *tracks* a
  # `pyvenv.cfg` as a fixture: the fixture has nothing to relocate, and dropping
  # a tracked directory from the copy would read as a deletion to
  # `CloneArtifactService`.
  VIRTUALENV_SCRIPT_DIRECTORIES = %w[bin Scripts].freeze

  # Never descended into, whatever the caller excludes — the three trees that
  # dominate a clone's directory count and cannot hold a Python environment
  # worth relocating. Skipping them is most of what keeps this scan cheap
  # enough to run before a copy that has not started yet. Written as the same
  # fnmatch patterns a caller's exclusions use, so both go through one test.
  ALWAYS_PRUNED = [ "**/.git", "**/node_modules", "vendor/bundle" ].freeze

  # fnmatch metacharacters, escaped so a detected path is matched literally.
  # `copy_pruned` matches without FNM_NOESCAPE, so a backslash escape is honored.
  FNMATCH_METACHARACTERS = /([*?\[\]{}\\])/

  # The flags `RealFileSystemAdapter#copy_pruned` matches its exclusions with.
  # Restated here so a caller's patterns are tested against a candidate exactly
  # as the copy will test them.
  FNMATCH_FLAGS = File::FNM_PATHNAME | File::FNM_DOTMATCH

  class << self
    # The non-relocatable directories inside a clone.
    #
    # @param clone_path [String] the root of the clone about to be copied
    # @param file_system [FileSystemAdapter, nil] defaults to the real one
    # @param prune [Array<String>] the caller's own copy exclusions, as fnmatch
    #   patterns relative to the clone root. A directory the copy will not write
    #   is not walked either — the walk is the cost, so filtering its results
    #   would save nothing.
    # @param logger [#warn] where a scan that could not finish is reported.
    #   `clones:relocate` passes one that writes to the task's own output; a
    #   failure nobody sees is a venv silently copied.
    # @return [Array<String>] paths relative to the clone root, sorted and
    #   unique. Never includes the clone root itself — the walk only ever
    #   considers a root's descendants.
    def detect(clone_path, file_system: nil, prune: [], logger: Rails.logger)
      return [] if clone_path.blank?

      fs = file_system || RealFileSystemAdapter.new
      root = File.expand_path(clone_path)
      return [] unless fs.directory?(root)

      found = []
      scan(fs, root, nil, ALWAYS_PRUNED | Array(prune), found)
      found.sort
    rescue SystemCallError, IOError => e
      # A tree this cannot read is copied whole — the pre-existing behaviour —
      # rather than failing the fork or the relocation outright. Deliberately
      # narrow: an ArgumentError or NoMethodError here is a bug in this class,
      # and swallowing it would restore exactly the silent staleness the class
      # exists to prevent, so it is left to raise.
      logger.warn("[NonRelocatableClonePaths] Could not scan #{clone_path}: #{e.message}")
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

    # Walks the clone one directory at a time rather than globbing it, so the
    # scan can stop descending: at the dependency and history trees above, at
    # anything the caller is already excluding from the copy, and at a
    # virtualenv itself — nothing inside one is separately interesting, and
    # stopping there is also what keeps a nested marker from being reported
    # twice.
    #
    # Symlinked directories are not followed, which matches what the copy does
    # with them (`copy_pruned` hands a symlink to `FileUtils.copy_entry`, which
    # copies the link rather than the tree behind it) and makes a symlink loop
    # impossible.
    #
    # `directory?` is asked first because most entries in a clone are files, and
    # for a file it is the only question that has to be answered at all.
    def scan(fs, root, relative, prune, found)
      directory = relative ? File.join(root, relative) : root

      fs.children(directory).each do |name|
        child = relative ? File.join(relative, name) : name
        path = File.join(root, child)

        next unless fs.directory?(path)
        next if fs.symlink?(path)
        next if excluded?(child, prune)

        if virtualenv?(fs, path)
          found << child
          next
        end

        scan(fs, root, child, prune, found)
      end
    end

    # A `pyvenv.cfg` plus the script directory whose contents carry the absolute
    # shebang. Both, because only the pair is evidence of something to relocate.
    def virtualenv?(fs, path)
      return false unless fs.exists?(File.join(path, VIRTUALENV_MARKER))

      VIRTUALENV_SCRIPT_DIRECTORIES.any? { |dir| fs.directory?(File.join(path, dir)) }
    end

    def excluded?(relative, prune)
      prune.any? { |pattern| File.fnmatch?(pattern, relative, FNMATCH_FLAGS) }
    end
  end
end
