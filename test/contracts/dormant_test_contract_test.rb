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
    dormant = (Minitest::Runnable.runnables - [ VisibilityProbe ]).flat_map do |klass|
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

  test "no test file on disk defines a test method under a non-public default visibility" do
    # This file is the one legitimate exception: VisibilityProbe defines both
    # dormant forms on purpose, and the two tests above assert that they are in
    # fact dormant.
    files = Dir[Rails.root.join("test/**/*_test.rb")].sort - [ __FILE__ ]
    offenders = files.flat_map { |path| DormantTestScanner.new(path).offenders }

    assert_empty offenders, <<~MSG
      A `def test_...` or a literal `define_method(:test_...)` written below a
      class-body-level `private`/`protected` defines a method Minitest will not
      collect. Move it above the visibility marker, or rewrite it as a
      `test "..."` block — those stay public:

      #{offenders.map { |o| "  - #{o}" }.join("\n")}
    MSG
  end

  test "the scanner detects both dormant definition styles and leaves test blocks alone" do
    file = Tempfile.new([ "dormant_probe", "_test.rb" ])
    file.write(<<~RUBY)
      class ProbeTest < ActiveSupport::TestCase
        def test_public_def; end

        private

        test "declarative stays public" do
        end

        def test_hidden_def; end
        define_method(:test_hidden_define_method) { }

        class Nested < ActiveSupport::TestCase
          def test_visibility_resets_per_body; end
        end
      end
    RUBY
    file.close

    found = DormantTestScanner.new(file.path).offenders.map { |o| o.split.last }

    assert_equal [ "test_hidden_def", "test_hidden_define_method" ], found.sort
  ensure
    file&.unlink
  end

  # Walks a test file's syntax tree tracking the default visibility of each class
  # or module body, and reports any test method defined while that visibility is
  # not public. Visibility resets on entry to a nested body, which mirrors Ruby: a
  # `private` in a nested class does not leak back out to its enclosing one.
  class DormantTestScanner
    TEST_METHOD = /\Atest_/
    VISIBILITY = %i[public private protected].freeze

    def initialize(path)
      @path = path
      @offenders = []
    end

    def offenders
      result = Prism.parse_file(@path.to_s)
      return [] if result.failure?

      walk(result.value.statements, :public)
      @offenders
    end

    private

    # `statements` is the body of one class/module/program; `visibility` is what is
    # in force when that body starts. Offenders accumulate on the instance.
    def walk(statements, visibility)
      return if statements.nil?

      statements.body.each do |stmt|
        case stmt
        when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
          walk(stmt.body, :public)
        when Prism::CallNode
          marker = visibility_marker(stmt)
          name = marker ? nil : defined_test_name(stmt)

          if marker
            visibility = marker
          elsif name && visibility != :public
            record(stmt, name)
          end
        when Prism::DefNode
          record(stmt, stmt.name) if dormant_def?(stmt, visibility)
        end
      end
    end

    def dormant_def?(node, visibility)
      node.receiver.nil? && visibility != :public && node.name.to_s.match?(TEST_METHOD)
    end

    # A bare `private` / `public` / `protected` is the only form that changes the
    # body's default visibility. `private def foo` and `private :foo` scope a
    # single method and leave the default alone.
    def visibility_marker(call)
      return nil unless call.receiver.nil?
      return nil unless VISIBILITY.include?(call.name)
      return nil if call.arguments || call.block

      call.name
    end

    # `define_method(:test_x)` written literally in a class body — the one call
    # form that does pick up the body's default visibility.
    def defined_test_name(call)
      return nil unless call.receiver.nil?
      return nil unless call.name == :define_method

      first = call.arguments&.arguments&.first
      name = first.unescaped if first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)
      name if name&.match?(TEST_METHOD)
    end

    def record(node, name)
      @offenders << "#{display_path}:#{node.location.start_line} #{name}"
    end

    def display_path
      Pathname.new(@path.to_s).relative_path_from(Rails.root).to_s
    rescue ArgumentError
      @path.to_s
    end
  end
end
