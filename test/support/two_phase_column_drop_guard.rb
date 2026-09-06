# frozen_string_literal: true

# Prism is a Ruby 3.4 default gem, so this resolves with or without a bundle —
# which is what lets the guard run in CI's `lint` job, with no services and no
# Rails boot.
require "prism"

# Finds migrations that make a column or a table stop answering to the name the
# running image compiled against, in one deploy instead of two.
#
# kamal-proxy health-gates the cutover, so old and new containers run together
# until the new one answers `/up`, and `bin/docker-entrypoint` has already run
# `db:prepare` by then. For the length of that window the OLD processes serve
# against the NEW schema.
#
# 20260815100000_drop_blocked_by_session_from_sessions dropped a column that way
# and cost 12 ERROR records in 12.8s across three poller jobs, which crossed the
# log-error alert threshold and paged #alerts (zimmer#482). The old processes
# booted with the column present, so their models still defined the attribute,
# but their SELECTs came back without it and reading it raised
# ActiveModel::MissingAttributeError.
#
# The mechanism was never specific to dropping a column, so neither is this
# guard (zimmer#722). Four shapes reproduce it, and each carries its own recipe
# and its own annotation:
#
#   :column_drop   remove_column & friends, t.remove, raw `DROP COLUMN`
#                  -> # two-phase-drop: phase 2 of <ref>
#   :column_rename rename_column, t.rename, `ALTER TABLE … RENAME COLUMN`
#   :table_rename  rename_table, `ALTER TABLE … RENAME TO`
#   :table_drop    drop_table, raw `DROP TABLE`
#                  -> # expand-contract: contract of <ref>
#
# A rename and a table drop take the `expand-contract` annotation rather than
# the drop one because they assert a different fact. `two-phase-drop` says an
# `ignored_columns` deploy shipped; `expand-contract` says an earlier deploy
# left the old NAME unread and unwritten by the running image, which for a
# rename is the end of an add-dual-write-backfill-switch sequence, not a
# one-line model change. See docs/src/content/docs/operate/deploying.md,
# "Dropping a column takes two deploys" and "Renames and table drops expand
# before they contract".
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

  # Shape by method name, for the calls that are unambiguous on their own.
  # `rename_index` and `remove_index` are absent on purpose: an index carries no
  # attribute and no query of the old container names it, so neither strands
  # anything mid-swap.
  METHOD_SHAPES = (
    DROP_METHODS.to_h { |name| [ name, :column_drop ] }
  ).merge(
    rename_column: :column_rename,
    rename_table: :table_rename,
    drop_table: :table_drop
  ).freeze

  # `t.remove` / `t.rename` inside a `change_table` block. Only counted when the
  # receiver is a local variable — which is exactly what a `change_table do |t|`
  # parameter is. A bare `remove` is something else entirely, and `File.rename`
  # in a data migration is not a schema change at all.
  RECEIVER_METHOD_SHAPES = { remove: :column_drop, rename: :column_rename }.freeze

  # Bodies that run in the reverse direction. A `remove_column` in here is the
  # undo of an `add_column`, not a drop, and the column only disappears if
  # someone rolls back. The same goes for the `drop_table` that closes the
  # `down` of nearly every `create_table` migration in this repo.
  #
  # Pruning is by method *name*, not by reachability, so a removal factored out
  # of `down` into a helper is still reported. Inline it into `down` rather than
  # annotating a phase 1 that never happened.
  REVERSING_BLOCKS = %i[down revert].freeze

  # Raw SQL, matched against string *contents* so a heredoc counts — which is
  # how anyone actually writes SQL in a migration. Postgres spells a table
  # rename `RENAME TO` and a column rename `RENAME [COLUMN] old TO new`, so the
  # table form is tried first and the column form has to refuse a bare `TO`.
  # The bare `RENAME COLUMN` entry is there for the interpolated spelling —
  # `"… RENAME COLUMN #{old} TO #{new}"` reaches the visitor as fragments, and
  # no fragment of it satisfies `\w+\s+TO`.
  SQL_SHAPES = {
    /\bDROP\s+COLUMN\b/i => :column_drop,
    /\bDROP\s+TABLE\b/i => :table_drop,
    /\bRENAME\s+TO\b/i => :table_rename,
    /\bRENAME\s+COLUMN\b/i => :column_rename,
    /\bRENAME\s+(?!TO\b)\w+\s+TO\b/i => :column_rename
  }.freeze

  # A rename is only a hazard when it is a TABLE being altered. `ALTER INDEX …
  # RENAME TO` is how the zero-downtime index swap ends, and `ALTER TYPE` /
  # `ALTER SEQUENCE` are no more visible to an old container than an index is —
  # so the raw-SQL rename shapes are recorded only while the statement in scope
  # is an `ALTER TABLE`. Tracked across string nodes, not within one: Prism
  # hands a squiggly heredoc to the visitor one line at a time, and the
  # realistic heredoc puts `ALTER TABLE sessions` and `RENAME TO …` on separate
  # lines. The scope resets at each enclosing call, so one `execute` cannot lend
  # its `ALTER TABLE` to the next.
  ALTER_TARGET = /\bALTER\s+(TABLE|INDEX|SEQUENCE|TYPE|VIEW|MATERIALIZED\s+VIEW)\b/i
  RENAME_SHAPES = %i[column_rename table_rename].freeze

  # What each shape has to say for itself. `:column_drop` keeps the original
  # annotation; the three name-changing shapes share the other one, so one
  # `expand-contract` annotation clears every name change in the file. The
  # annotation is per kind rather than per hazard — the same latitude the
  # original one always had, since a migration doing two things at once is
  # already asking a reviewer to read it as a whole.
  SHAPE_ANNOTATIONS = {
    column_drop: :two_phase_drop,
    column_rename: :expand_contract,
    table_rename: :expand_contract,
    table_drop: :expand_contract
  }.freeze

  ANNOTATIONS = {
    two_phase_drop: /\A\s*#\s*two-phase-drop:\s*phase\s*2\s+of\s+(\S.*?)\s*\z/,
    expand_contract: /\A\s*#\s*expand-contract:\s*contract\s+of\s+(\S.*?)\s*\z/
  }.freeze

  # The annotation has to name something a reviewer can go and read: a PR or
  # issue number, a commit sha, or the phase-1 migration's version. "phase 2 of
  # the earlier PR" is not evidence that phase 1 shipped. The sha branch is
  # loose enough to accept a hex-looking word (`deadbeef`); tightening it buys
  # nothing, since the point is to make the author name a thing, not to resolve
  # it.
  REF = /(?:#\d+)|(?:\b[0-9a-f]{7,40}\b)|(?:\b\d{14}\b)/

  # Single-phase changes that shipped before the guard covered their shape. They
  # are history: the columns are long gone and the tables answer to their new
  # names, so rewriting a migration that already ran buys nothing. The list is
  # closed — GRANDFATHER_CUTOFF is what keeps it that way, so a new drop or
  # rename gets the deploys and the annotation instead.
  #
  # The three renames were invisible to the guard until zimmer#722; the drops
  # predate the guard entirely. The last drop is the argument for the whole
  # file: #680 dropped that column in one phase on 2026-08-28, twelve days after
  # the incident and nine after it was written up, because nothing was checking.
  GRANDFATHERED = %w[
    20251114181607_rename_repository_url_to_git_root_and_add_subdirectory.rb
    20251120202242_remove_filesystem_root_from_sessions.rb
    20260221002859_create_trigger_conditions.rb
    20260310214653_remove_claude_agents_from_sessions.rb
    20260503180000_rename_stop_condition_to_goal.rb
    20260529120000_rename_agent_type_to_agent_runtime_and_drop_claude_skills.rb
    20260704120000_add_extension_states_to_app_settings.rb
    20260815100000_drop_blocked_by_session_from_sessions.rb
    20260823030300_replace_spot_targets_with_priority_reserve.rb
    20260828160000_remove_provenance_via_mcp_enabled_from_app_settings.rb
  ].freeze

  # The day the guard landed. Every grandfathered migration predates it,
  # including the renames added when the detected set widened.
  GRANDFATHER_CUTOFF = "20260831000000"

  Hazard = Struct.new(:line, :source, :shape, keyword_init: true) do
    def annotation_kind = SHAPE_ANNOTATIONS.fetch(shape)
  end

  # One scanned migration. `annotations` maps an annotation kind to the
  # reference it names, and holds only the kinds the file actually carries.
  Result = Struct.new(:path, :hazards, :annotations, keyword_init: true) do
    def hazardous? = hazards.any?
    def shapes = hazards.map(&:shape).uniq
    def annotated?(kind) = annotations.key?(kind)
    def proven?(kind) = annotations[kind].to_s.match?(REF)
    def unproven_hazards = hazards.reject { |hazard| proven?(hazard.annotation_kind) }
    def basename = File.basename(path)
  end

  class << self
    def scan_file(path)
      new(path).scan
    end

    # Every migration in `dir` that changes a column or table name away from
    # what the running image compiled against, in the forward direction, oldest
    # first. Files that do none of that are not returned at all.
    def scan_directory(dir = MIGRATION_DIR)
      Dir[File.join(dir, "*.rb")].sort.filter_map do |path|
        result = scan_file(path)
        result if result.hazardous?
      end
    end

    # The policy: a forward drop or rename needs either a grandfathered pass or
    # the annotation its shape calls for, naming a reference.
    def violations(dir = MIGRATION_DIR)
      scan_directory(dir)
        .reject { |result| GRANDFATHERED.include?(result.basename) }
        .select { |result| result.unproven_hazards.any? }
    end

    # What a contributor reads when the guard fails. Empty string when clean, so
    # it doubles as the standalone command's output. One block per shape, since
    # a migration that renames one column and drops another needs both recipes.
    def report(violations = self.violations)
      violations.flat_map { |result|
        result.unproven_hazards.group_by(&:shape).map do |shape, hazards|
          violation_message(result, shape, hazards)
        end
      }.join("\n")
    end

    # The other half of the two-phase drop: deploy 2 drops the column AND
    # removes the `ignored_columns` entry. An entry naming a column that is
    # already gone is a phase-2 cleanup someone forgot.
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

    def violation_message(result, shape, hazards)
      lines = hazards.map { |hazard| "  line #{hazard.line}: #{hazard.source}" }

      <<~MESSAGE
        #{result.basename} #{HEADLINES.fetch(shape)}:
        #{lines.join("\n")}

        #{RECIPES.fetch(shape)}
      MESSAGE
    end
  end

  HEADLINES = {
    column_drop: "drops a column in the forward direction",
    column_rename: "renames a column in the forward direction",
    table_rename: "renames a table in the forward direction",
    table_drop: "drops a table in the forward direction"
  }.freeze

  DOCS = "docs/src/content/docs/operate/deploying.md"

  RECIPES = {
    column_drop: <<~MESSAGE,
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

      #{DOCS}, "Dropping a column takes two deploys".
    MESSAGE
    column_rename: <<~MESSAGE,
      A rename is a drop and an add in the same instant, and the OLD containers keep
      serving through the health-gated swap. Their SELECTs come back with the new
      name and without the old one, so reading the attribute they booted with raises
      ActiveModel::MissingAttributeError — byte for byte the failure of zimmer#482 —
      and their INSERTs still name the old column, which is now PG::UndefinedColumn.

      Nothing renames in place. Expand, then contract:

        1. Add the new column. Write BOTH names, and backfill from a post-deploy
           task, which runs after the cutover — so rows the old containers wrote
           during the swap window are covered too.
        2. Switch every read to the new name. Keep writing both.
        3. Stop writing the old name: `ignored_columns`, and drop the dual-write.
        4. In a LATER pull request, drop the old column and annotate it
           `# two-phase-drop: phase 2 of #<ref>`.

      If the old name is ALREADY unread and unwritten by the deployed image — an
      earlier deploy removed every reference to it — say so, and name that deploy:

        # expand-contract: contract of #474

      #{DOCS}, "Renames and table drops expand before they contract".
    MESSAGE
    table_rename: <<~MESSAGE,
      The OLD containers keep serving through the health-gated swap and their
      queries still name the old table, so every one of them raises
      PG::UndefinedTable until kamal-proxy cuts over. That is worse than
      zimmer#482: not one attribute on one model, every query against the table.

      Expand, then contract: create the new table, write both, backfill from a
      post-deploy task, switch reads, stop writing the old table, and drop it in a
      LATER pull request. A rename that only makes the name nicer is rarely worth
      that — leave the table alone and set `self.table_name` on the model.

      If an earlier deploy already left the old table unread and unwritten, name it:

        # expand-contract: contract of #474

      #{DOCS}, "Renames and table drops expand before they contract".
    MESSAGE
    table_drop: <<~MESSAGE
      The OLD containers keep serving through the health-gated swap, and any query
      they still make against the table raises PG::UndefinedTable — every query,
      not one attribute.

      Split it across two deploys:

        1. Delete the model and every reference to it — association, fixture,
           dashboard, job. Ship that on its own. Nothing then queries the table,
           in either the old image or the new one.
        2. In a LATER pull request, drop the table and name the deploy that
           emptied it:

             # expand-contract: contract of #474

      The reference has to be a PR/issue number, a commit sha, or the first
      migration's version — something a reviewer can go and read.

      #{DOCS}, "Renames and table drops expand before they contract".
    MESSAGE
  }.freeze

  def initialize(path)
    @path = path.to_s
    @source = File.read(@path)
  end

  # Parsed rather than grepped, because the direction is a syntactic fact:
  # `def down`, `dir.down { }` and `revert { }` are all reversals, and a regex
  # over the file cannot tell them from the forward body two lines above. The
  # annotations come off the parsed comments for the same reason — over raw
  # text, a `# two-phase-drop:` line inside a SQL heredoc would read as evidence.
  def scan
    parsed = Prism.parse(@source)
    raise ArgumentError, "#{@path} does not parse: #{parsed.errors.first&.message}" if parsed.failure?

    collector = Collector.new
    parsed.value.accept(collector)

    Result.new(path: @path, hazards: collector.hazards.sort_by(&:line), annotations: annotations(parsed))
  end

  private

  # Per kind, the first annotation that names a reference wins, so a stray
  # earlier one cannot mask a real one; failing that, the first annotation of
  # that kind at all, so the error message can still say what was written.
  def annotations(parsed)
    ANNOTATIONS.filter_map { |kind, pattern|
      written = parsed.comments.filter_map { |comment| comment.slice[pattern, 1] }
      next if written.empty?

      [ kind, written.find { |ref| ref.match?(REF) } || written.first ]
    }.to_h
  end

  # Walks the AST, refusing to descend into anything that runs in reverse.
  class Collector < Prism::Visitor
    attr_reader :hazards

    def initialize
      @hazards = []
      @sql_target = nil
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

      # `execute <<~SQL … SQL` is one call holding many string nodes, and the
      # `ALTER TABLE` that scopes them is in the first. The next call starts over.
      @sql_target = nil

      shape = shape_of(node)
      push(node, shape) if shape
      super
    end

    # Any string literal, not just an argument to `execute` — that also covers
    # `connection.execute`, a SQL constant, and the heredoc forms, and the
    # reversing-body pruning above still applies to all of them.
    def visit_string_node(node)
      push_sql(node)
      super
    end

    private

    def shape_of(node)
      METHOD_SHAPES[node.name] ||
        (node.receiver.is_a?(Prism::LocalVariableReadNode) ? RECEIVER_METHOD_SHAPES[node.name] : nil)
    end

    def push(node, shape)
      @hazards << Hazard.new(line: node.location.start_line, source: node.slice.lines.first.strip, shape: shape)
    end

    # Line by line, so a heredoc that drops two columns reports both, each at the
    # line it is written on — Prism's call-node slice stops at the `<<~SQL`
    # marker, so matching the *call* source would miss every realistic one. SQL
    # comments are skipped: a `-- drop the widget column once #123 lands` note
    # is a plan, not a statement.
    def push_sql(node)
      node.unescaped.lines.each_with_index do |line, offset|
        next if line.strip.start_with?("--")

        @sql_target = line[ALTER_TARGET, 1].upcase.squeeze(" ") if line.match?(ALTER_TARGET)

        shapes(line).each do |shape|
          @hazards << Hazard.new(line: node.location.start_line + offset, source: line.strip, shape: shape)
        end
      end
    end

    # Every distinct shape on the line, not just the first: one line can both
    # drop a column and rename a table, and two patterns can name the same shape.
    def shapes(line)
      SQL_SHAPES
        .filter_map { |pattern, shape| shape if line.match?(pattern) }
        .uniq
        .reject { |shape| RENAME_SHAPES.include?(shape) && @sql_target != "TABLE" }
    end
  end
end
