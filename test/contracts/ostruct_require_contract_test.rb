# frozen_string_literal: true

require "test_helper"
require "prism"

# A test file that names OpenStruct without requiring "ostruct" is broken on its
# own and green in the suite.
#
# `ostruct` is a bundled gem rather than a default one — nothing requires it for
# you, and `ruby -e 'OpenStruct'` raises NameError on the Ruby this repo runs.
# Test files are loaded into one process, so the FIRST file that requires it
# satisfies every file loaded after it. That is why the full suite passes: the
# requires already present are doing the work for the files that lack them, and
# which files those are depends on nothing more principled than the order the
# runner happens to load them in.
#
# Run one file on its own and the borrowed require is gone:
#
#     $ bin/rails test test/config/webpush_config_test.rb
#     NameError: uninitialized constant WebpushConfigTest::OpenStruct
#         test/config/webpush_config_test.rb:47
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
# the constant: a mention in a comment or a string does not need a require, and
# a commented-out `require "ostruct"` does not supply one.
#
# Scope is deliberately this one gem. `require "mocha/minitest"` is the same
# shape of bug with a different constant and is tracked on its own in
# zimmer#764; folding it in here would couple two fixes that can land
# separately.
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
        pass in a full-suite run only because some earlier file required it, and
        raise NameError when run on their own:

        #{offenders.map { |path| "  #{relative(path)}" }.join("\n")}

        Add the require below `require "test_helper"`:

          require "#{REQUIRED_FEATURE}"

        `#{REQUIRED_FEATURE}` is a bundled gem, so nothing requires it for you. See
        zimmer#787.
      MESSAGE
  end

  # The guard is only worth having if it can see a violation, and the repo is
  # (as of this file) clean — so the positive case is exercised against source
  # built here rather than against a file on disk.
  test "detects a file that uses the constant without the require" do
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

  private

  def ruby_files
    Dir[Rails.root.join("test", "**", "*.rb")].sort
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Rails.root).to_s
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

    def visit_call_node(node)
      @requires_feature = true if require_of_feature?(node)

      super
    end

    private

    # `require "ostruct"` written literally. A dynamic require is not something
    # this contract tries to understand — nothing in test/ does it, and reading
    # one as satisfying the requirement would be a guess.
    def require_of_feature?(node)
      return false unless node.name == :require && node.receiver.nil?

      argument = node.arguments&.arguments&.first

      argument.is_a?(Prism::StringNode) && argument.unescaped == REQUIRED_FEATURE
    end
  end
end
