# frozen_string_literal: true

require "test_helper"
# Prism is a Ruby 3.4 default gem, so this resolves with or without a Gemfile
# entry — the same dependency `test/support/two_phase_column_drop_guard.rb`
# leans on.
require "prism"
require "tempfile"

# A test file that names OpenStruct without requiring "ostruct" is broken on its
# own and green in the suite.
#
# `ostruct` ships with Ruby but is not required for you: it is a default gem on
# 3.4 and a bundled one from 3.5, and under neither does `OpenStruct` resolve
# until something requires it. `ruby -e 'OpenStruct'` raises NameError.
#
# Test files are loaded into one process, so the FIRST file that requires it
# satisfies every file loaded after it. That is why the full suite passes: the
# requires already present are doing the work for the files that lack them, and
# which files those are depends on nothing more principled than the order the
# runner happens to load them in. Run one file on its own and the borrowed
# require is gone, leaving `NameError: uninitialized constant OpenStruct` on the
# first line that names it.
#
# Which is the workflow AGENTS.md prescribes — "Run **targeted** tests locally;
# let CI run the full suite" — so the cost lands on whoever is iterating on a
# subset, in the form of an unrelated error they have to recognise and discount.
# That is the moment a real regression is easiest to wave through.
#
# zimmer#787 is that bug. Twenty files under test/ name OpenStruct; nineteen had
# accumulated the require one at a time, two of them with a comment explaining
# why. This contract is what makes the twentieth the last one, instead of the
# convention decaying again the next time a file is added.
#
# Source is parsed, not grepped, because the question is whether the file *uses*
# the constant. A mention in a comment or a string does not need a require, a
# commented-out `require "ostruct"` does not supply one, and defining or
# reopening a class of that name is not a use of the gem's.
#
# What it cannot see is the dynamic forms — `Object.const_get(:OpenStruct)`,
# `"OpenStruct".constantize`, a `require` whose argument is computed. Reading any
# of those would be a guess, nothing in test/ writes them, and the failure mode
# is a violation slipping through rather than a false alarm.
#
# Scope is deliberately this one gem. The same shape with `mocha/minitest` is
# `mocha_require_contract_test.rb` next door, which also carries the rule about a
# require landing in `test/support/**` becoming a de-facto suite-wide one, since
# `test_helper.rb` loads that directory for every run (zimmer#874).
class OstructRequireContractTest < ActiveSupport::TestCase
  # `OpenStruct` parses to a constant read; `::OpenStruct` to a constant path
  # with no parent. Both name the top-level constant, so both need the require.
  CONSTANT = :OpenStruct

  REQUIRED_FEATURE = "ostruct"

  test "every test file that uses OpenStruct requires ostruct itself" do
    offenders = ruby_files.reject { |path| satisfied?(path) }

    assert_empty offenders.map { |path| relative(path) },
      <<~MESSAGE
        These files name #{CONSTANT} but do not require "#{REQUIRED_FEATURE}", so they
        pass in a full-suite run only because some other file required it first:

        #{offenders.map { |path| "  #{relative(path)}" }.join("\n")}

        Add the require below `require "test_helper"`:

          require "#{REQUIRED_FEATURE}"

        `#{REQUIRED_FEATURE}` ships with Ruby but is not required for you. See zimmer#787.
      MESSAGE
  end

  # The guard's value is entirely in its ability to fail, and `offenders` is
  # empty both when the tree is clean and when the glob has stopped matching
  # anything. Pin the glob so a wrong root or a renamed directory cannot turn
  # the contract above into a permanent, silent pass.
  test "the scan actually reaches the test tree" do
    scanned = ruby_files.map { |path| relative(path) }

    assert_operator scanned.length, :>, 100
    assert_includes scanned, "test/config/webpush_config_test.rb"
    assert_includes scanned, "test/contracts/#{File.basename(__FILE__)}"
  end

  # `satisfied?` reads from disk, which the source-level tests below never
  # exercise. A real file on each side of the verdict covers that half.
  test "reads a real file from disk on both sides of the verdict" do
    assert_not satisfied?(tempfile_containing("#{CONSTANT}.new"))
    assert satisfied?(tempfile_containing("require \"#{REQUIRED_FEATURE}\"\n#{CONSTANT}.new"))
  end

  test "detects a use without the require" do
    assert_equal [ :uses ], analyze(<<~RUBY).compact
      require "test_helper"

      #{CONSTANT}.new(a: 1)
    RUBY

    assert_equal %i[uses requires], analyze(<<~RUBY).compact
      require "test_helper"
      require "#{REQUIRED_FEATURE}"

      ::#{CONSTANT}.new(a: 1)
    RUBY
  end

  test "a mention in a comment or a string is not a use" do
    assert_empty analyze(<<~RUBY).compact
      # #{CONSTANT} would be wrong here
      puts "#{CONSTANT}"
    RUBY
  end

  test "a commented-out require does not satisfy a real use" do
    assert_equal [ :uses ], analyze(<<~RUBY).compact
      # require "#{REQUIRED_FEATURE}"
      #{CONSTANT}.new
    RUBY
  end

  # A file that defines its own stand-in is not reaching for the gem's, so it
  # needs no require. The body still counts: a class named after the constant is
  # not a licence to use the real one inside it.
  test "defining a class or module of that name is not a use" do
    assert_empty analyze(<<~RUBY).compact
      class #{CONSTANT}
        def initialize(**) = nil
      end
    RUBY

    assert_empty analyze(<<~RUBY).compact
      module Fake
        class #{CONSTANT}; end
      end

      Fake::#{CONSTANT}.new
    RUBY

    assert_equal [ :uses ], analyze(<<~RUBY).compact
      class Wrapper
        def build = #{CONSTANT}.new
      end
    RUBY
  end

  # Reopening something *inside* OpenStruct does name the constant, and needs it
  # to exist.
  test "a definition nested under the constant is a use" do
    assert_equal [ :uses ], analyze("class #{CONSTANT}::Extension; end").compact
  end

  # `defined?` is the one context where naming a constant explicitly does not
  # require it to exist — that is what the operator is for.
  test "defined? is not a use" do
    assert_empty analyze("puts \"yes\" if defined?(#{CONSTANT})").compact
  end

  # Both of these really do load the gem, so both really do satisfy the
  # requirement.
  test "an explicit Kernel receiver and an .rb suffix both satisfy the require" do
    assert_equal %i[uses requires], analyze(<<~RUBY).compact
      Kernel.require "#{REQUIRED_FEATURE}"
      #{CONSTANT}.new
    RUBY

    assert_equal %i[uses requires], analyze(<<~RUBY).compact
      require "#{REQUIRED_FEATURE}.rb"
      #{CONSTANT}.new
    RUBY
  end

  private

  def ruby_files
    Dir[Rails.root.join("test", "**", "*.rb")].sort
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Rails.root).to_s
  end

  def tempfile_containing(source)
    file = Tempfile.new([ "ostruct_contract", ".rb" ])
    file.write(source)
    file.close
    file.path
  end

  def satisfied?(path)
    facts = analyze(File.read(path), path)

    !facts.include?(:uses) || facts.include?(:requires)
  end

  # Returns [:uses, :requires] — either element nil when absent — so the two
  # detectors can be asserted on independently above.
  def analyze(source, path = "(inline source)")
    parsed = Prism.parse(source)
    raise ArgumentError, "#{path} does not parse: #{parsed.errors.first&.message}" if parsed.failure?

    collector = Collector.new
    parsed.value.accept(collector)

    [ (:uses if collector.uses_constant), (:requires if collector.requires_feature) ]
  end

  class Collector < Prism::Visitor
    attr_reader :uses_constant, :requires_feature

    def visit_constant_read_node(node)
      @uses_constant = true if node.name == CONSTANT

      super
    end

    # Only the parentless form, which is `::OpenStruct`. A path with a parent is
    # somebody else's constant that happens to share the name — `Foo::OpenStruct`
    # needs no require, and `OpenStruct::Bar` is caught above by its own parent.
    def visit_constant_path_node(node)
      @uses_constant = true if node.parent.nil? && node.name == CONSTANT

      super
    end

    # `class OpenStruct` / `module OpenStruct` name the constant they are about
    # to define, which is the opposite of depending on it existing. Descend into
    # everything else — the body, the superclass, and any namespace the name is
    # nested under, since `class OpenStruct::Extension` genuinely does need it.
    def visit_class_node(node)
      visit_namespace(node.constant_path)
      visit(node.superclass)
      visit(node.body)
    end

    def visit_module_node(node)
      visit_namespace(node.constant_path)
      visit(node.body)
    end

    # `defined?(OpenStruct)` is the one place naming the constant does not
    # require it to resolve.
    def visit_defined_node(node)
      return if names_constant?(node.value)

      super
    end

    def visit_call_node(node)
      @requires_feature = true if require_of_feature?(node)

      super
    end

    private

    # The name being defined is not a use; whatever it is nested under is.
    def visit_namespace(constant_path)
      visit(constant_path.parent) if constant_path.is_a?(Prism::ConstantPathNode)
    end

    def names_constant?(node)
      case node
      when Prism::ConstantReadNode then node.name == CONSTANT
      when Prism::ConstantPathNode then node.parent.nil? && node.name == CONSTANT
      else false
      end
    end

    # `require "ostruct"` in the forms that actually load it: with or without an
    # explicit `Kernel` receiver, with or without the `.rb` suffix. A computed
    # argument is not something this contract tries to understand.
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
