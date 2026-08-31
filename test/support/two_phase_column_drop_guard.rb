# frozen_string_literal: true

# Prism is a Ruby 3.4 default gem, so this resolves with or without a bundle —
# which is what lets the guard run in CI's `lint` job, with no services and no
# Rails boot.
require "prism"

# Finds migrations that drop a column in one deploy instead of two.
#
# kamal-proxy health-gates the cutover, so old and new containers run together
# until the new one answers `/up`, and `bin/docker-entrypoint` has already run
# `db:prepare` by then. For the length of that window the OLD processes serve
# against the NEW schema: they booted with the column present, so their model
# still defines the attribute, but their SELECTs come back without it and
# reading it raises ActiveModel::MissingAttributeError.
#
# 20260815100000_drop_blocked_by_session_from_sessions did exactly that and cost
# 12 ERROR records in 12.8s across three poller jobs, which crossed the
# log-error alert threshold and paged #alerts (zimmer#482).
#
# The remedy is two deploys, and the annotation below is how a migration says it
# is the second one. See docs/src/content/docs/operate/deploying.md,
# "Dropping a column takes two deploys".
#
# Scope: column *removals* only. `rename_column`, `rename_table` and `drop_table`
# strand an old container exactly the same way and are deliberately not caught
# here — their phase 1 is not an `ignored_columns` entry but an add-and-backfill,
# which is a different recipe this guard does not have an annotation for
# (zimmer#722).
#
# Deliberately Rails-free: it reads files, so it runs on its own without a
# database. TwoPhaseColumnDropTest is its wiring into `bin/rails test`, the
# `lint` job runs it directly, and
#
#   bundle exec ruby -r./test/support/two_phase_column_drop_guard \
#     -e 'puts TwoPhaseColumnDropGuard.report'
#
# is the same check by hand.
class TwoPhaseColumnDropGuard
  MIGRATION_DIR = File.expand_path("../../db/migrate", __dir__)

  # `remove_reference` is on this list because it is what actually shipped the
  # incident — it drops `<name>_id`, and a guard that only knew `remove_column`
  # would have waved the migration in zimmer#482 straight through.
  DROP_METHODS = %i[remove_column remove_columns remove_reference remove_belongs_to].freeze

  # `t.remove` inside a `change_table` block. Only counted when it has a
  # receiver, so a bare `remove` — something else entirely — does not trip it.
  RECEIVER_DROP_METHODS = %i[remove].freeze

  # Bodies that run in the reverse direction. A `remove_column` in here is the
  # undo of an `add_column`, not a drop, and the column only disappears if
  # someone rolls back.
  #
  # Pruning is by method *name*, not by reachability, so a removal factored out
  # of `down` into a helper is still reported. Inline it into `down` rather than
  # annotating a phase 1 that never happened.
  REVERSING_BLOCKS = %i[down revert].freeze

  # Raw SQL, matched against string *contents* so a heredoc counts — which is
  # how anyone actually writes SQL in a migration.
  DROP_COLUMN_SQL = /DROP\s+COLUMN/i

  ANNOTATION = /\A\s*#\s*two-phase-drop:\s*phase\s*2\s+of\s+(\S.*?)\s*\z/

  # The annotation has to name something a reviewer can go and read: a PR or
  # issue number, a commit sha, or the phase-1 migration's version. "phase 2 of
  # the earlier PR" is not evidence that phase 1 shipped. The sha branch is
  # loose enough to accept a hex-looking word (`deadbeef`); tightening it buys
  # nothing, since the point is to make the author name a thing, not to resolve
  # it.
  REF = /(?:#\d+)|(?:\b[0-9a-f]{7,40}\b)|(?:\b\d{14}\b)/

  # Single-phase drops that shipped before this guard existed. They are history:
  # the columns are long gone, and rewriting a migration that already ran buys
  # nothing. The list is closed — GRANDFATHER_CUTOFF is what keeps it that way,
  # so a new drop gets the two-deploy treatment and the annotation instead.
  GRANDFATHERED = %w[
    20251120202242_remove_filesystem_root_from_sessions.rb
    20260221002859_create_trigger_conditions.rb
    20260310214653_remove_claude_agents_from_sessions.rb
    20260529120000_rename_agent_type_to_agent_runtime_and_drop_claude_skills.rb
    20260704120000_add_extension_states_to_app_settings.rb
    20260815100000_drop_blocked_by_session_from_sessions.rb
  ].freeze

  # The day the guard landed. Every grandfathered migration predates it.
  GRANDFATHER_CUTOFF = "20260824000000"

  Removal = Struct.new(:line, :source, keyword_init: true)

  # One scanned migration. `annotation` is nil when the file carries none.
  Result = Struct.new(:path, :removals, :annotation, keyword_init: true) do
    def drops_columns? = removals.any?
    def annotated? = !annotation.nil?
    def annotation_names_a_ref? = annotated? && annotation.match?(REF)
    def basename = File.basename(path)
  end

  class << self
    def scan_file(path)
      new(path).scan
    end

    # Every migration in `dir` that removes a column in the forward direction,
    # oldest first. Files that remove nothing are not returned at all.
    def scan_directory(dir = MIGRATION_DIR)
      Dir[File.join(dir, "*.rb")].sort.filter_map do |path|
        result = scan_file(path)
        result if result.drops_columns?
      end
    end

    # The policy: a forward drop needs either a grandfathered pass or an
    # annotation that names its phase-1 reference.
    def violations(dir = MIGRATION_DIR)
      scan_directory(dir)
        .reject { |result| GRANDFATHERED.include?(result.basename) }
        .reject(&:annotation_names_a_ref?)
    end

    # What a contributor reads when the guard fails. Empty string when clean, so
    # it doubles as the standalone command's output.
    def report(violations = self.violations)
      violations.map { |result| violation_message(result) }.join("\n")
    end

    # The other half of the convention: deploy 2 drops the column AND removes
    # the `ignored_columns` entry. An entry naming a column that is already gone
    # is a phase-2 cleanup someone forgot.
    #
    # `models` is anything responding to `name` and `ignored_columns`; the block
    # returns the column names the table really has. Both are injected so this
    # stays testable without a database — Active Record's own `column_names`
    # could never detect it, since it filters `ignored_columns` out itself.
    def stale_ignored_columns(models)
      models.flat_map do |model|
        ignored = Array(model.ignored_columns).map(&:to_s)
        next [] if ignored.empty?

        (ignored - yield(model)).map { |column| "#{model.name}.ignored_columns: #{column}" }
      end
    end

    private

    def violation_message(result)
      lines = result.removals.map { |removal| "  line #{removal.line}: #{removal.source}" }

      <<~MESSAGE
        #{result.basename} drops a column in the forward direction:
        #{lines.join("\n")}

        A one-phase drop breaks the OLD containers, which keep serving through the
        health-gated swap: they booted with the column present, so their model still
        has the attribute, but their SELECTs come back without it and raise
        ActiveModel::MissingAttributeError. That is zimmer#482 — 12 errors in 12.8s
        across three poller jobs, and a page to #alerts.

        Split it across two deploys:

          1. Add the column to the model's `ignored_columns` and remove every code
             reference to it. Ship that on its own. Nothing then reads the column,
             in either the old image or the new one.
          2. In a LATER pull request, drop the column, remove the `ignored_columns`
             entry, and annotate the migration with the phase-1 reference:

               # two-phase-drop: phase 2 of #474

        The reference has to be a PR/issue number, a commit sha, or the phase-1
        migration's version — something a reviewer can go and read.

        docs/src/content/docs/operate/deploying.md, "Dropping a column takes two deploys".
      MESSAGE
    end
  end

  def initialize(path)
    @path = path.to_s
    @source = File.read(@path)
  end

  # Parsed rather than grepped, because the direction is a syntactic fact:
  # `def down`, `dir.down { }` and `revert { }` are all reversals, and a regex
  # over the file cannot tell them from the forward body two lines above. The
  # annotation comes off the parsed comments for the same reason — over raw text,
  # a `# two-phase-drop:` line inside a SQL heredoc would read as evidence.
  def scan
    parsed = Prism.parse(@source)
    raise ArgumentError, "#{@path} does not parse: #{parsed.errors.first&.message}" if parsed.failure?

    collector = Collector.new
    parsed.value.accept(collector)

    Result.new(path: @path, removals: collector.removals.sort_by(&:line), annotation: annotation(parsed))
  end

  private

  # The first annotation that names a reference wins, so a stray earlier one
  # cannot mask a real one; failing that, the first annotation at all, so the
  # error message can still say what was written.
  def annotation(parsed)
    written = parsed.comments.filter_map { |comment| comment.slice[ANNOTATION, 1] }

    written.find { |ref| ref.match?(REF) } || written.first
  end

  # Walks the AST, refusing to descend into anything that runs in reverse.
  class Collector < Prism::Visitor
    attr_reader :removals

    def initialize
      @removals = []
      super
    end

    def visit_def_node(node)
      return if REVERSING_BLOCKS.include?(node.name)

      super
    end

    def visit_call_node(node)
      # `dir.down do ... end` / `revert do ... end`. Only a call that takes a
      # block is a reversing *body*: `revert 20260101000000` reverts a whole
      # other migration and has nothing here to inspect.
      return if node.block && REVERSING_BLOCKS.include?(node.name)

      push(node) if drop_call?(node)
      super
    end

    # Any string literal, not just an argument to `execute` — that also covers
    # `connection.execute`, a SQL constant, and the heredoc forms, and the
    # reversing-body pruning above still applies to all of them.
    def visit_string_node(node)
      push_sql(node) if node.unescaped.match?(DROP_COLUMN_SQL)
      super
    end

    private

    def drop_call?(node)
      DROP_METHODS.include?(node.name) ||
        (RECEIVER_DROP_METHODS.include?(node.name) && node.receiver)
    end

    def push(node)
      @removals << Removal.new(line: node.location.start_line, source: node.slice.lines.first.strip)
    end

    def push_sql(node)
      lines = node.unescaped.lines
      offset = lines.index { |line| line.match?(DROP_COLUMN_SQL) } || 0

      @removals << Removal.new(line: node.location.start_line + offset, source: lines[offset].strip)
    end
  end
end
