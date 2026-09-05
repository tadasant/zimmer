# frozen_string_literal: true

# Decides, for one directory sitting under a runtime's per-working-directory
# transcript root (`~/.claude/projects` for Claude Code), whether the working
# directory that produced it still exists.
#
# Why this is its own object
# --------------------------
# The directory name is a one-way function of the cwd — `PathSanitizer` maps
# `/`, `.` and `_` all onto `-`, so `-home-rails--zimmer-clones-zimmer-main-…`
# cannot be turned back into a path. The only sound way to attribute a name is to
# go the *forward* direction: take every working directory that is still live,
# run it through the same derivation the runtime's TranscriptSource uses, and
# compare. That is what this does, and it is why it needs the source injected
# rather than a slug rule of its own.
#
# Three answers, and only one of them deletes
# -------------------------------------------
#   :live      — a working directory that still exists produced this.
#   :orphaned  — nothing that exists could have produced it, AND its shape says
#                what did: a clone that is gone, or a cwd under an ephemeral root
#                (`/tmp`) that does not survive a container restart.
#   :unknown   — anything else. `-rails` (cwd `/rails`, the app root inside the
#                container) is the live example; a developer's own project
#                transcripts are another. **Kept.**
#
# `:unknown` is the default, not an error case. Deleting a live session's
# transcript directory destroys the file `--resume` reads — the conversation
# exists nowhere else on disk — while keeping an orphan costs a few hundred
# kilobytes until someone widens the rules. So every uncertainty resolves to
# keeping.
#
# The subdirectory case (zimmer#434)
# ----------------------------------
# An agent root with a `subdirectory` runs with cwd `<clone>/<subdir>`, so its
# transcript directory is named for THAT, not for the clone root:
#
#   /home/rails/.zimmer/clones/zimmer-main-1785661439-005ceef3/zimmer
#     -> -home-rails--zimmer-clones-zimmer-main-1785661439-005ceef3-zimmer
#
# A classifier that maps clone name -> directory name by equality alone calls
# that orphaned and deletes a running session's transcript. So a live clone
# claims its own derived name AND every name extending it by `-<something>`.
# Nothing else can wear that prefix: clone directory names end in a random hex
# suffix (`{repo}-{branch}-{timestamp}-{random}`, GitCloneService), so one clone's
# derived name is never a prefix of another's — and if two ever did collide, the
# collision resolves to `:live`, which keeps.
class TranscriptDirectoryClassifier
  # Filesystem roots whose contents do not survive a container restart, so a
  # transcript directory derived from a cwd beneath one of them can never have a
  # live cwd behind it. `/tmp` is where the headless-inference lane runs: 2,543
  # of production's 6,612 transcript directories were `-tmp-headless-inference-*`
  # when zimmer#434 was measured, and no clone-based sweep would ever reach them.
  #
  # Membership here is a claim that the root is *wiped*, not merely temporary.
  # An age bar still applies on top (see OrphanTranscriptDirectoryCleanupJob), so
  # a cwd under /tmp that a process is using right now is not a candidate.
  EPHEMERAL_CWD_ROOTS = [ "/tmp" ].freeze

  # @param transcript_source [TranscriptSource] the runtime source whose root is
  #   being classified; supplies the cwd -> directory derivation
  # @param clones_base [String] the clones base directory
  # @param live_clone_names [Enumerable<String>] basenames of clone directories
  #   that still exist, or that a reap-protected session still claims
  def initialize(transcript_source:, clones_base:, live_clone_names:)
    @source = transcript_source
    @clones_base = File.expand_path(clones_base.to_s)
    @clones_base_name = derive(@clones_base)
    @live_names = live_clone_names
      .filter_map { |name| derive(File.join(@clones_base, name.to_s)) }
      .to_set
    @ephemeral_names = EPHEMERAL_CWD_ROOTS.filter_map { |root| derive(root) }
  end

  # @param entry [String] a directory name directly under the transcript root
  # @return [Symbol] :live, :orphaned or :unknown
  def classify(entry)
    return :unknown if entry.blank?

    if clone_derived?(entry)
      return :live if @live_names.any? { |name| covers?(name, entry) }

      return :orphaned
    end

    return :orphaned if @ephemeral_names.any? { |name| covers?(name, entry) }

    :unknown
  end

  # The transcript directory NAME a working directory produces, through the
  # runtime's own derivation. nil when the source declines to derive one.
  #
  # @param working_directory [String] a cwd
  # @return [String, nil]
  def self.derived_name(transcript_source:, working_directory:)
    path = transcript_source.transcript_directory(working_directory: working_directory)
    return nil if path.blank?

    File.basename(path)
  end

  # Whether `entry` is a directory `clone_path` could have produced — the clone's
  # own name, or one extending it by `-<subdirectory>`. Used by
  # TranscriptDirectoryReaper on the clone-deletion path, where the same prefix
  # rule that spares a live subdirectory cwd here has to *catch* it there.
  #
  # Derives the name on every call, so a caller scanning a whole transcript root
  # against one clone should hoist `derived_name` out of its loop and call
  # `covers?` directly — that root holds thousands of entries.
  #
  # @param clone_path [String] a clone directory
  # @param entry [String] a directory name under the transcript root
  # @return [Boolean]
  def self.derived_from?(transcript_source:, clone_path:, entry:)
    covers?(
      derived_name(transcript_source: transcript_source,
                   working_directory: File.expand_path(clone_path.to_s)),
      entry
    )
  end

  # Whether `name` — a directory name derived from some working directory —
  # claims `entry`, either as itself or as an ancestor cwd of it.
  def self.covers?(name, entry)
    return false if name.blank? || entry.blank?

    entry == name || entry.start_with?("#{name}-")
  end

  private

  def covers?(name, entry)
    self.class.covers?(name, entry)
  end

  # Whether `entry` was derived from a cwd strictly beneath the clones base.
  #
  # Strictly: `entry == @clones_base_name` is the clones base ITSELF as a cwd,
  # which belongs to no clone and is left to `:unknown`.
  def clone_derived?(entry)
    return false if @clones_base_name.blank?

    entry.start_with?("#{@clones_base_name}-")
  end

  def derive(working_directory)
    self.class.derived_name(transcript_source: @source, working_directory: working_directory)
  end
end
