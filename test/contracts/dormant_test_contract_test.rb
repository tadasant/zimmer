# frozen_string_literal: true

require "test_helper"
require "prism"
require "tempfile"

# A test method that is not public is a test method that never runs.
#
# Minitest::Runnable.runnable_methods collects `public_instance_methods` only, so
# a test defined while its class body's default visibility is private is silently
# dropped: no failure, no skip, no mention in the run count. The suite stays green
# while the coverage is gone.
#
# Two definition styles are exposed to that, and a third one — the one this
# codebase actually uses — is not:
#
#   private
#   def test_thing; end               # private -> dormant
#   define_method(:test_thing) { }    # private -> dormant
#   test "thing" do ... end           # public  -> runs
#
# The last one stays public because ActiveSupport::Testing::Declarative#test calls
# define_method from inside a method body. Default visibility belongs to the
# class-body frame; a call out to a helper does not carry it, so the method lands
# public no matter what precedes the `test` block.
#
# That distinction was the subject of https://github.com/tadasant/zimmer/issues/350,
# which counted 143 `test` blocks sitting below a class-level `private` and read
# them as dormant. They were all running. This file is what pins that down —
# and, more usefully, what fails the build if the genuinely dormant forms ever
# appear.
#
# Coverage is deliberately doubled up, because each half misses what the other
# catches:
#
#   - The runtime half is ground truth: it asks the loaded classes what Minitest
#     would collect. But it only sees classes loaded into this process, and
#     `bin/rails test` does not descend into test/system.
#   - The static half parses every `*_test.rb` on disk, system tests included, so
#     nothing is out of reach. It reasons about source rather than about the
#     objects Minitest will run.
class DormantTestContractTest < ActiveSupport::TestCase
  # Exercises all three definition styles under a class-level `private`, using the
  # real `test` helper and the real Minitest collection path rather than a
  # reimplementation of either. It is unregistered immediately below so the suite
  # does not try to run it.
  class VisibilityProbe < ActiveSupport::TestCase
    private

    test "from declarative helper" do
      :ran
    end

    define_method(:test_from_literal_define_method) { :ran }

    def test_from_def_keyword
      :ran
    end
  end
  Minitest::Runnable.runnables.delete(VisibilityProbe)

  test "a test block below a class-level private is still collected by Minitest" do
    assert_equal [ "test_from_declarative_helper" ],
                 VisibilityProbe.runnable_methods.sort,
                 "the `test` helper defines public methods regardless of the surrounding default visibility"
  end

  test "def and literal define_method below a class-level private are not collected" do
    hidden = VisibilityProbe.private_instance_methods(false).grep(/\Atest_/).map(&:to_s).sort

    assert_equal [ "test_from_def_keyword", "test_from_literal_define_method" ],
                 hidden,
                 "these forms do honor the class body's default visibility, which is what makes them dangerous"

    refute_includes VisibilityProbe.runnable_methods, "test_from_def_keyword"
    refute_includes VisibilityProbe.runnable_methods, "test_from_literal_define_method"
  end

  test "no loaded test class hides a test method behind private or protected" do
    dormant = Minitest::Runnable.runnables.flat_map do |klass|
      hidden = klass.private_instance_methods(false) + klass.protected_instance_methods(false)
      hidden.grep(/\Atest_/).map { |m| "#{klass}##{m}" }
    end.sort

    assert_empty dormant, <<~MSG
      These test methods are not public, so Minitest never runs them and never
      reports them as skipped. Move them above the class-level `private`, or
      define them with a `test "..."` block:

      #{dormant.map { |d| "  - #{d}" }.join("\n")}
    MSG
  end

  test "no ruby file under test/ defines a test method under a non-public default visibility" do
    # Everything under test/, not just *_test.rb: a shared module in test/support
    # that goes private takes its cases down with it, and the runtime half cannot
    # see that at all — private_instance_methods(false) does not report methods
    # contributed by an included module.
    #
    # This file is the one exclusion. VisibilityProbe defines both dormant forms
    # on purpose, and the two tests above assert that they really are dormant.
    self_path = File.realpath(__FILE__)
    files = Dir[Rails.root.join("test/**/*.rb")].sort.reject { |p| File.realpath(p) == self_path }
    offenders = files.flat_map { |path| DormantTestScanner.new(path).offenders }

    assert_empty offenders, <<~MSG
      A `def test_...` or a literal `define_method(:test_...)` written below a
      class-body-level `private`/`protected` defines a method Minitest will not
      collect. Move it above the visibility marker, or rewrite it as a
      `test "..."` block — those stay public:

      #{offenders.map { |o| "  - #{o}" }.join("\n")}
    MSG
  end

  # One fixture, every shape worth pinning: the two dormant forms, the three ways
  # a visibility marker can be spelled, the single-method forms that do not move
  # the default, and the bodies where a `private` must not leak.
  test "the scanner flags every dormant shape and nothing else" do
    found = scan(<<~RUBY)
      class ProbeTest < ActiveSupport::TestCase
        def test_public_def; end
        private def test_single_method_form; end
        private :test_public_def
        module_function def test_module_function_arg; end

        private

        test "declarative stays public" do
          :not_a_definition
        end

        def test_hidden_def; end
        define_method(:test_hidden_define_method) { }
        define_method("test_hidden_string_name") { }

        if RUBY_VERSION > "3"
          def test_hidden_inside_a_conditional; end
        end

        class << self
          def test_singleton_is_never_collected; end
        end

        class Nested < ActiveSupport::TestCase
          def test_visibility_resets_per_body; end
        end
      end

      class SendProbeTest < ActiveSupport::TestCase
        send(:private)
        def test_hidden_after_send; end
      end

      module SharedCases
        module_function

        def test_hidden_after_module_function; end
      end

      class ConditionalProbeTest < ActiveSupport::TestCase
        if RUBY_VERSION > "3"
          private
        end

        def test_hidden_after_a_conditional_marker; end
      end
    RUBY

    assert_equal [
      "test_hidden_after_a_conditional_marker",
      "test_hidden_after_module_function",
      "test_hidden_after_send",
      "test_hidden_def",
      "test_hidden_define_method",
      "test_hidden_inside_a_conditional",
      "test_hidden_string_name",
      "test_module_function_arg",
      "test_public_def",
      "test_single_method_form"
    ], found.map { |o| o.split.last }.sort
  end

  test "a class body the scanner cannot parse is reported rather than passed over" do
    offenders = scan("class Broken < ActiveSupport::TestCase\n  def test_x")

    assert_equal 1, offenders.size
    assert_match(/could not be parsed/, offenders.first)
  end

  # Writes `source` to a throwaway file and returns the scanner's raw offender
  # lines, sorted.
  def scan(source)
    file = Tempfile.new([ "dormant_probe", "_test.rb" ])
    file.write(source)
    file.close

    DormantTestScanner.new(file.path).offenders.sort
  ensure
    file&.unlink
  end

  # Walks a file's syntax tree tracking the default visibility of each class or
  # module body, and reports any test method that ends up non-public. Visibility
  # resets on entry to a nested body, which mirrors Ruby: a `private` in a nested
  # class does not leak back out to its enclosing one.
  #
  # Two deliberate choices about the fuzzy edges:
  #
  #   - A `private` inside an `if`/`unless`/`case` propagates to the statements
  #     after it, and a definition inside such a branch is judged by the
  #     visibility in force there. Ruby only runs one branch, so this errs toward
  #     flagging. A conditional visibility marker in a test class body is not a
  #     thing anyone writes on purpose, and a false positive here is a comment
  #     away from resolved, where a false negative is the failure mode this whole
  #     contract exists to prevent.
  #   - `class << self` is skipped entirely. Those are singleton methods, and
  #     Minitest collects instance methods, so nothing in there can be dormant.
  class DormantTestScanner
    TEST_METHOD = /\Atest_/
    VISIBILITY = %i[public private protected].freeze
    # `module_function` with no arguments makes every subsequent instance method
    # private, exactly like `private` does.
    NON_PUBLIC_MARKERS = %i[private protected module_function].freeze

    def initialize(path)
      @path = path
      @offenders = []
    end

    # A file that will not parse is reported, not skipped. Ruby cannot load it
    # either, so the suite has bigger problems — but a guard against silently
    # absent coverage has no business going silent itself.
    def offenders
      result = Prism.parse_file(@path.to_s)
      return [ "#{display_path} could not be parsed" ] if result.failure?

      walk(result.value.statements, :public, false)
      @offenders
    end

    private

    # Walks one body's statements and returns the default visibility left in force
    # after them, so a marker inside a nested `if` reaches the statements below it.
    # `flagging` says whether definitions in this body can become Minitest tests at
    # all. Offenders accumulate on the instance.
    def walk(node, visibility, flagging)
      statements(node).each { |stmt| visibility = walk_statement(stmt, visibility, flagging) }
      visibility
    end

    def walk_statement(stmt, visibility, flagging)
      case stmt
      when Prism::ClassNode, Prism::ModuleNode
        walk(stmt.body, :public, test_body?(stmt))
        visibility
      when Prism::SingletonClassNode
        visibility
      when Prism::DefNode
        record(stmt, stmt.name) if flagging && dormant_def?(stmt, visibility)
        visibility
      when Prism::CallNode
        walk_call(stmt, visibility, flagging)
      when Prism::BeginNode
        # A bare `begin` or a body with a rescue/ensure clause: linear, so the
        # visibility it leaves behind is simply the last one set.
        [ stmt.statements, stmt.rescue_clause, stmt.else_clause, stmt.ensure_clause ]
          .compact.reduce(visibility) { |v, clause| walk(clause, v, flagging) }
      when Prism::IfNode, Prism::UnlessNode, Prism::CaseNode
        branches(stmt).reduce(visibility) { |v, branch| walk(branch, v, flagging) }
      else
        visibility
      end
    end

    def walk_call(call, visibility, flagging)
      return walk_block(call, visibility, flagging) unless call.receiver.nil?

      marker = bare_visibility_marker(call)
      return marker if marker

      if flagging
        scoped_test_names(call).each { |node, name| record(node, name) }

        name = literal_define_method_name(call)
        record(call, name) if name && visibility != :public
      end

      walk_block(call, visibility, flagging)
    end

    # `included do ... end`, `class_eval do ... end`, `concerning ... do` — a `def`
    # in there is an instance method of the eventual includer, and a `private`
    # above it applies. The block opens its own default-public frame and cannot
    # change the enclosing body's, so nothing propagates back out.
    def walk_block(call, visibility, flagging)
      walk(call.block.body, :public, flagging) if call.block.is_a?(Prism::BlockNode)
      visibility
    end

    # Whether an instance method defined in this body can end up as a Minitest test:
    # a test case class, or any module, which exists under test/ to be mixed into
    # one. A plain class that is neither — `class FakeParameterStore`, whose fake of
    # the GCP API legitimately has a private `test_iam_permissions` — is not a place
    # a test can hide, and flagging it would be noise.
    def test_body?(node)
      return true if node.is_a?(Prism::ModuleNode)

      name = node.constant_path.slice
      superclass = node.superclass&.slice.to_s

      name.end_with?("Test") || superclass.end_with?("Test", "TestCase")
    end

    def dormant_def?(node, visibility)
      node.receiver.nil? && visibility != :public && node.name.to_s.match?(TEST_METHOD)
    end

    # A bare `private` / `protected` / `public` / `module_function`, including the
    # `send(:private)` spelling, is what moves the body's default visibility.
    def bare_visibility_marker(call)
      name = call.name
      if %i[send __send__].include?(name)
        first = call.arguments&.arguments
        return nil unless first&.one?

        name = first.first.is_a?(Prism::SymbolNode) ? first.first.unescaped.to_sym : nil
      elsif call.arguments || call.block
        return nil
      end

      return :private if name == :module_function
      name if VISIBILITY.include?(name)
    end

    # The single-method forms — `private def test_x; end`, `private :test_x`,
    # `module_function def test_x; end`. These do not move the default, but they do
    # hide the one method they name, which is the same dormancy.
    def scoped_test_names(call)
      return [] unless NON_PUBLIC_MARKERS.include?(call.name)

      Array(call.arguments&.arguments).filter_map do |arg|
        case arg
        when Prism::DefNode
          [ arg, arg.name.to_s ] if arg.receiver.nil? && arg.name.to_s.match?(TEST_METHOD)
        when Prism::SymbolNode, Prism::StringNode
          [ arg, arg.unescaped ] if arg.unescaped.match?(TEST_METHOD)
        when Prism::CallNode
          name = literal_define_method_name(arg)
          [ arg, name ] if name
        end
      end
    end

    # `define_method(:test_x)` written literally in a body — the one call form that
    # picks up that body's default visibility.
    def literal_define_method_name(call)
      return nil unless call.receiver.nil?
      return nil unless call.name == :define_method

      first = call.arguments&.arguments&.first
      name = first.unescaped if first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)
      name if name&.match?(TEST_METHOD)
    end

    # Prism hands a body back as a StatementsNode, as a BeginNode when the body
    # carries a rescue/ensure clause, as one of the clause nodes that wrap their
    # own statements, or as nil when it is empty.
    def statements(node)
      case node
      when nil then []
      when Prism::StatementsNode then node.body
      when Prism::RescueNode, Prism::ElseNode, Prism::EnsureNode then statements(node.statements)
      else [ node ]
      end
    end

    # `if` chains hang their else/elsif off `subsequent`, `unless` off
    # `else_clause`, and `case` off its `when` conditions plus `else_clause`.
    def branches(node)
      case node
      when Prism::IfNode then [ node.statements, node.subsequent ]
      when Prism::UnlessNode then [ node.statements, node.else_clause ]
      when Prism::CaseNode then node.conditions.map(&:statements) + [ node.else_clause ]
      else []
      end.compact
    end

    def record(node, name)
      @offenders << "#{display_path}:#{node.location.start_line} #{name}"
    end

    def display_path
      path = Pathname.new(@path.to_s)
      path.absolute? ? path.relative_path_from(Rails.root).to_s : path.to_s
    end
  end
end
