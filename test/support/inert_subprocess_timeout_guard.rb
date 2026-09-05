# frozen_string_literal: true

# Prism is a Ruby 3.4 default gem, so this resolves with or without a bundle —
# the same dependency `test/support/two_phase_column_drop_guard.rb` leans on.
require "prism"

# Finds `Timeout.timeout { Open3.capture3(...) }`, which bounds nothing.
#
# `Open3.capture3` runs its body inside `Open3.popen_run`, whose `ensure` closes
# the parent pipe ends and then calls `wait_thr.join`. When `Timeout::Error` is
# raised in the calling thread it unwinds *through that ensure*, and the join
# blocks until the child exits on its own. The child is never signalled. So the
# call takes exactly as long as the child does; all the timeout changes is that
# the return value is replaced by a `Timeout::Error` **after** the wait.
#
# Measured on this repo's Ruby (3.4.6) — a 1s timeout around an 8s child:
#
#   Timeout.timeout(1) { Open3.capture3("sh", "-c", "trap '' TERM; sleep 8") }
#   # => rescued Timeout::Error after 8.01s
#
# It also dumps two `report_on_exception` thread-death backtraces to stderr on
# every fire (`IOError: stream closed in another thread`, from the two reader
# threads `capture3` spawns) — unactionable noise in worker logs.
#
# zimmer#908 is that bug: seven call sites, two of them on the
# `waiting → running` session launch path, each believing it had a wall-clock
# limit it did not have. The remedy is `BoundedSubprocess.run(cmd, timeout:)`,
# which spawns the child as its own process-group leader, drains its pipes under
# an `IO.select` deadline, and SIGKILLs the whole group when the deadline passes.
#
# This guard is what stops the pattern coming back. It is seductive precisely
# because it reads as correct, so nothing but a machine reliably catches it.
#
# Deliberately Rails-free: it reads files, so it runs on its own without a
# database. InertSubprocessTimeoutTest is its wiring into `bin/rails test`, and
#
#   bundle exec ruby -r./test/support/inert_subprocess_timeout_guard \
#     -e 'puts InertSubprocessTimeoutGuard.report'
#
# is the same check by hand.
class InertSubprocessTimeoutGuard
  ROOT = File.expand_path("../..", __dir__)

  # Application code. `db/post_deploy` is in scope because a post-deploy task is
  # exactly the unattended-in-production shape this bug is worst in, and `.rake`
  # is scanned alongside `.rb` because lib/tasks already shells out. Test code is
  # out of scope: a test that deliberately builds the pattern — this guard's own
  # fixtures, for one — is describing it, not shipping it.
  SCAN_DIRS = %w[app lib db/post_deploy].freeze

  SCAN_EXTENSIONS = %w[rb rake].freeze

  # Every Open3 entry point that joins its wait thread in an `ensure`, not just
  # `capture3`. The `capture*`/`popen*` family goes through `popen_run`; the
  # `pipeline*` family goes through `pipeline_run`, whose ensure does the same
  # thing across every stage (`wait_thrs.each(&:join)`). Same defect, so a guard
  # that knew only the one site zimmer#908 happened to use would wave the next
  # one through.
  INERT_OPEN3_METHODS = %i[
    capture2 capture2e capture3
    popen2 popen2e popen3
    pipeline pipeline_r pipeline_rw pipeline_start pipeline_w
  ].freeze

  TIMEOUT_METHOD = :timeout

  # One offending `Timeout.timeout` call. `subprocess_line` / `subprocess_source`
  # point at the `Open3.…` call nested inside it, which is the line to change.
  Finding = Struct.new(:path, :line, :subprocess_line, :subprocess_source, keyword_init: true) do
    def relative_path = path.delete_prefix("#{ROOT}/")
  end

  class << self
    def scan_file(path)
      new(path).scan
    end

    # Every offending call under `dirs`, path order, then line order.
    def violations(dirs = SCAN_DIRS)
      ruby_files(dirs).flat_map { |path| scan_file(path) }
    end

    # What a contributor reads when the guard fails. Empty string when clean, so
    # it doubles as the standalone command's output.
    def report(violations = self.violations)
      return "" if violations.empty?

      sites = violations.map do |finding|
        "  #{finding.relative_path}:#{finding.line} " \
          "(#{finding.subprocess_source} on line #{finding.subprocess_line})"
      end

      <<~MESSAGE
        Timeout.timeout around an Open3 subprocess call bounds nothing:

        #{sites.join("\n")}

        Open3 runs the block inside `popen_run`, whose `ensure` calls
        `wait_thr.join`. The Timeout::Error unwinds through that join, which blocks
        until the child exits on its own — the child is never signalled. The call
        takes as long as the child takes; the timeout only swaps the return value
        for an exception after the fact. Measured on Ruby 3.4.6, a 1s timeout
        around an 8s child returned after 8.01s (zimmer#908).

        Use BoundedSubprocess instead. It spawns the child as its own process-group
        leader, drains stdout/stderr under an IO.select deadline, and SIGKILLs the
        whole group when the deadline passes:

          stdout, stderr, status = BoundedSubprocess.run([bin, "--version"], timeout: 10)
        rescue BoundedSubprocess::TimeoutError
          # the branch the `rescue Timeout::Error` already took

        Note the signature: a command ARRAY plus `env:` / `cwd:` keywords, and a
        status that may be nil — read it through `SubprocessStatus.success?`, never
        `status.success?` (zimmer#271).
      MESSAGE
    end

    # Ruby sources under `dirs`, sorted so output is stable across machines.
    # Entries are resolved against the repo root, so "app" and an absolute
    # fixture directory both work.
    def ruby_files(dirs = SCAN_DIRS)
      dirs.flat_map do |dir|
        Dir[File.join(File.expand_path(dir, ROOT), "**", "*.{#{SCAN_EXTENSIONS.join(',')}}")]
      end.sort
    end
  end

  def initialize(path)
    @path = path.to_s
    @source = File.read(@path)
  end

  # Parsed rather than grepped, because "in the same expression" is a syntactic
  # question. The two calls are on different lines with anything in between, a
  # regex over the file cannot tell a `Timeout.timeout` wrapping a `capture3`
  # from one fifty lines above an unrelated `capture3`, and a mention in a
  # comment or a docstring is not a call at all.
  def scan
    parsed = Prism.parse(@source)
    raise ArgumentError, "#{@path} does not parse: #{parsed.errors.first&.message}" if parsed.failure?

    collector = Collector.new(@path)
    parsed.value.accept(collector)
    collector.findings.sort_by { |finding| [ finding.line, finding.subprocess_line ] }
  end

  # Walks the AST looking for `Timeout.timeout`, then walks whatever that call
  # encloses — block body *and* arguments — for an inert Open3 call.
  class Collector < Prism::Visitor
    attr_reader :findings

    def initialize(path)
      @path = path
      @findings = []
      super()
    end

    def visit_call_node(node)
      return super unless timeout_call?(node)

      nested = NestedOpen3Finder.new
      node.accept(nested)
      nested.calls.each do |call|
        @findings << Finding.new(
          path: @path,
          line: node.location.start_line,
          subprocess_line: call.location.start_line,
          subprocess_source: "Open3.#{call.name}"
        )
      end

      # Deliberately no `super`: NestedOpen3Finder already walked this whole
      # subtree, so descending would report every call again for each enclosing
      # `Timeout.timeout` — one site, N findings.
    end

    private

    # `Timeout.timeout` and `Timeout::timeout` both parse to a call on the
    # constant. A bare `timeout(…)` from `include Timeout` is not matched — the
    # receiver is what makes it recognisable, and nothing in the repo does that.
    def timeout_call?(node)
      node.name == TIMEOUT_METHOD && constant_named?(node.receiver, "Timeout")
    end

    def constant_named?(receiver, name)
      case receiver
      when Prism::ConstantReadNode then receiver.name.to_s == name
      when Prism::ConstantPathNode then receiver.name.to_s == name
      else false
      end
    end
  end

  # Collects `Open3.<inert method>` calls anywhere beneath the node it visits.
  class NestedOpen3Finder < Prism::Visitor
    attr_reader :calls

    def initialize
      @calls = []
      super()
    end

    def visit_call_node(node)
      @calls << node if open3_call?(node)
      super
    end

    private

    def open3_call?(node)
      return false unless INERT_OPEN3_METHODS.include?(node.name)

      receiver = node.receiver
      case receiver
      when Prism::ConstantReadNode, Prism::ConstantPathNode then receiver.name.to_s == "Open3"
      else false
      end
    end
  end
end
