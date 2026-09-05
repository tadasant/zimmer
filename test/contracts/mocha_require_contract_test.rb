# frozen_string_literal: true

require "test_helper"
# Prism is a Ruby 3.4 default gem, so this resolves with or without a Gemfile
# entry — the same dependency `test/support/two_phase_column_drop_guard.rb` and
# the sibling ostruct contract lean on.
require "prism"
require "tempfile"

# A test file that calls mocha's API without requiring "mocha/minitest" is
# broken on its own and green in the suite.
#
# The gem is in the Gemfile, so `Bundler.require` loads `mocha` — but not the
# Minitest integration, which is what defines `stubs` and `expects` on Object.
# That arrives only with `require "mocha/minitest"`, and the suite shares one
# process, so the first file to require it satisfies every file loaded after it.
# Which files those are is decided by nothing more principled than the order the
# runner loads them in. Run one file on its own and the borrowed require is
# gone, leaving `NoMethodError: undefined method 'stubs'`.
#
# Which is the workflow AGENTS.md prescribes — "Run **targeted** tests locally;
# let CI run the full suite" — so the cost lands on whoever is iterating on a
# subset, in the form of an unrelated error they have to recognise and discount.
#
# zimmer#764 is one instance and zimmer#787 another. zimmer#874 is why they were
# hard to reproduce: `test/support/x_oauth_test_helpers.rb` carried a
# `require "mocha/minitest"`, and `test_helper.rb` auto-requires every file
# under `test/support/**`, so that one line was loading mocha for the whole
# suite. Twenty-one files had accumulated a dependency on it without saying so.
#
# Hence the two tests below. The first is the same shape as the ostruct
# contract: declare what you use. The second is what keeps the first meaningful
# — no auto-required support file may re-open the hole by requiring mocha on
# everyone's behalf.
#
# Source is parsed, not grepped, because the question is whether the file *calls*
# mocha. `expects` and `stubs` appear in prose in this tree far more often than
# in code, a mention in a string needs no require, and a commented-out require
# does not supply one.
#
# The auto-required helpers are exempt from the first rule for exactly the
# reason the second rule exists: a require in one of them would be suite-wide,
# so the two rules would contradict each other. `XOauthTestHelpers` and
# `McpAvailabilityHelpers` both stub, and both leave the require to their
# callers — which the contract cannot see, since it reads one file at a time.
# That is the gap: a test file whose only mocha use is inside a helper it calls
# gets no warning here, only a `NoMethodError` on the targeted run. The failure
# mode is a violation slipping through rather than a false alarm.
class MochaRequireContractTest < ActiveSupport::TestCase
  # Mocha's entry points, by call name. Every one of these is defined by
  # `mocha/minitest` and by nothing else in this tree — no `def stubs`,
  # `def expects`, `def any_instance` or `def stub_everything` exists in app/,
  # lib/ or test/.
  #
  # Deliberately absent are `stub` and `mock`. Mocha defines both, but so does
  # minitest-mock — `Object#stub` and `Minitest::Mock.new` — and this repo uses
  # the minitest ones (`ManagedSecret.stub(:openrouter_key, …) do`). Flagging
  # them would demand a mocha require of files that legitimately have no mocha
  # in them.
  CALLS = %i[stubs expects unstub any_instance stub_everything].freeze

  # `Mocha::Mockery.instance.teardown` — nine files reach for it to drop
  # expectations a background thread would otherwise trip over.
  CONSTANT = :Mocha

  # `require "mocha"` alone is not enough: it loads the gem without the Minitest
  # integration, so `stubs` still does not exist. Only this path counts.
  REQUIRED_FEATURE = "mocha/minitest"

  test "every test file that calls mocha requires mocha/minitest itself" do
    offenders = declaring_files.reject { |path| satisfied?(path) }

    assert_empty offenders.map { |path| relative(path) },
      <<~MESSAGE
        These files call mocha's API but do not require "#{REQUIRED_FEATURE}", so
        they pass in a full-suite run only because some other file required it first:

        #{offenders.map { |path| "  #{relative(path)}" }.join("\n")}

        Add the require below `require "test_helper"`:

          require "#{REQUIRED_FEATURE}"

        See zimmer#874.
      MESSAGE
  end

  # The other half, and the one that made the first half unenforceable until
  # now. `test_helper.rb` loads every one of these for every run, so a require
  # in any of them is a suite-wide require: it would satisfy the test above for
  # files that declare nothing, exactly as it did before #874.
  #
  # A support helper that stubs is fine — it just cannot declare the dependency
  # on its callers' behalf. See the comment on `XOauthTestHelpers`.
  test "no auto-required support file requires mocha on the suite's behalf" do
    offenders = AUTO_REQUIRED_SUPPORT_FILES.select { |path| requires_feature?(path) }

    assert_empty offenders.map { |path| relative(path) },
      <<~MESSAGE
        test_helper.rb auto-requires these files for every run, so a
        `require "#{REQUIRED_FEATURE}"` in one of them is a suite-wide require and
        masks its absence in every test file:

        #{offenders.map { |path| "  #{relative(path)}" }.join("\n")}

        Leave the require to the test files that call the helper. See zimmer#874.
      MESSAGE
  end

  # Both guards are empty-set assertions, which pass just as happily when the
  # inputs have gone empty. Pin both so a wrong root or a renamed directory
  # cannot turn this file into a permanent, silent pass.
  test "both scans actually reach the files they are about" do
    scanned = declaring_files.map { |path| relative(path) }

    assert_operator scanned.length, :>, 100
    assert_includes scanned, "test/services/orchestrator_system_prompt_builder_test.rb"
    assert_includes scanned, "test/contracts/#{File.basename(__FILE__)}"
    # Exempt from the first rule, and the subject of the second.
    assert_not_includes scanned, "test/support/x_oauth_test_helpers.rb"

    support = AUTO_REQUIRED_SUPPORT_FILES.map { |path| relative(path) }

    assert_operator support.length, :>, 10
    assert_includes support, "test/support/x_oauth_test_helpers.rb"
    # The loop skips `_test.rb`, so the second guard must too. That file is the
    # case it matters for: it is a support file's own test, it is not
    # auto-required, and it requires mocha — a false offender if the set drifted.
    assert_not_includes support, "test/support/air_catalog_cache_warmer_test.rb"
    assert_empty support.grep(/_test\.rb\z/)
  end

  # `satisfied?` and `requires_feature?` read from disk, which the source-level
  # tests below never exercise. A real file on each side of each verdict covers
  # that half.
  test "reads a real file from disk on both sides of the verdict" do
    bare = tempfile_containing("Foo.stubs(:bar)")
    declared = tempfile_containing("require \"#{REQUIRED_FEATURE}\"\nFoo.stubs(:bar)")

    assert_not satisfied?(bare)
    assert satisfied?(declared)

    assert_not requires_feature?(bare)
    assert requires_feature?(declared)
  end

  test "detects each of mocha's entry points" do
    CALLS.each do |call|
      assert_equal [ :uses ], analyze("Foo.#{call}(:bar)").compact, "#{call} with a receiver"
      assert_equal [ :uses ], analyze("#{call}(:bar)").compact, "#{call} without a receiver"
    end

    assert_equal [ :uses ], analyze("#{CONSTANT}::Mockery.instance.teardown").compact
  end

  test "a mention in a comment or a string is not a call" do
    assert_empty analyze(<<~RUBY).compact
      # `expects` with an exact argument would be too strict here
      puts "the suite expects one broadcast"
      puts "#{CONSTANT}"
    RUBY
  end

  # The names are ordinary enough that this matters: `:stubs` as a symbol, a
  # hash key, or a local variable is not a call into mocha.
  test "a symbol or a local variable of the same name is not a call" do
    assert_empty analyze(<<~RUBY).compact
      config = { stubs: true, expects: 1 }
      stubs = config[:stubs]
      puts stubs
    RUBY
  end

  test "a commented-out require does not satisfy a real call" do
    assert_equal [ :uses ], analyze(<<~RUBY).compact
      # require "#{REQUIRED_FEATURE}"
      Foo.stubs(:bar)
    RUBY
  end

  # `require "mocha"` loads the gem but not the Minitest integration, so it does
  # not define `stubs` and must not count.
  test "requiring the gem without the minitest integration does not satisfy the call" do
    assert_equal [ :uses ], analyze(<<~RUBY).compact
      require "mocha"
      Foo.stubs(:bar)
    RUBY
  end

  test "an explicit Kernel receiver and an .rb suffix both satisfy the require" do
    assert_equal %i[uses requires], analyze(<<~RUBY).compact
      Kernel.require "#{REQUIRED_FEATURE}"
      Foo.stubs(:bar)
    RUBY

    assert_equal %i[uses requires], analyze(<<~RUBY).compact
      require "#{REQUIRED_FEATURE}.rb"
      Foo.stubs(:bar)
    RUBY
  end

  private

  # Everything under test/ that is loaded because a run named it, rather than
  # because test_helper.rb loads it for every run.
  def declaring_files
    Dir[Rails.root.join("test", "**", "*.rb")].sort - AUTO_REQUIRED_SUPPORT_FILES
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Rails.root).to_s
  end

  def tempfile_containing(source)
    file = Tempfile.new([ "mocha_contract", ".rb" ])
    file.write(source)
    file.close
    file.path
  end

  def satisfied?(path)
    facts = analyze(File.read(path), path)

    !facts.include?(:uses) || facts.include?(:requires)
  end

  def requires_feature?(path)
    analyze(File.read(path), path).include?(:requires)
  end

  # Returns [:uses, :requires] — either element nil when absent — so the two
  # detectors can be asserted on independently above.
  def analyze(source, path = "(inline source)")
    parsed = Prism.parse(source)
    raise ArgumentError, "#{path} does not parse: #{parsed.errors.first&.message}" if parsed.failure?

    collector = Collector.new
    parsed.value.accept(collector)

    [ (:uses if collector.calls_mocha), (:requires if collector.requires_feature) ]
  end

  class Collector < Prism::Visitor
    attr_reader :calls_mocha, :requires_feature

    def visit_call_node(node)
      @calls_mocha = true if CALLS.include?(node.name)
      @requires_feature = true if require_of_feature?(node)

      super
    end

    def visit_constant_read_node(node)
      @calls_mocha = true if node.name == CONSTANT

      super
    end

    # Reached only for the `::Mocha::Mockery` form; the unqualified one arrives
    # as a constant read on the innermost parent.
    def visit_constant_path_node(node)
      @calls_mocha = true if root_of(node) == CONSTANT

      super
    end

    private

    # `Mocha::Mockery` is a path whose innermost parent names the constant.
    # `Foo::Mocha` is somebody else's and needs no require.
    def root_of(node)
      case node
      when Prism::ConstantPathNode then node.parent.nil? ? node.name : root_of(node.parent)
      when Prism::ConstantReadNode then node.name
      end
    end

    # `require "mocha/minitest"` in the forms that actually load it: with or
    # without an explicit `Kernel` receiver, with or without the `.rb` suffix. A
    # computed argument is not something this contract tries to understand.
    def require_of_feature?(node)
      return false unless node.name == :require && kernel_receiver?(node.receiver)

      argument = node.arguments&.arguments&.first

      argument.is_a?(Prism::StringNode) &&
        argument.unescaped.delete_suffix(".rb") == REQUIRED_FEATURE
    end

    def kernel_receiver?(receiver)
      receiver.nil? ||
        receiver.is_a?(Prism::SelfNode) ||
        (receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :Kernel)
    end
  end
end
