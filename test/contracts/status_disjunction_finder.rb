# frozen_string_literal: true

# Prism is a Ruby 3.4 default gem — the same dependency the mocha and ostruct
# contracts lean on.
require "prism"

# Required with require_relative by the contract tests that use it, rather than
# living in test/support, because everything there is loaded for every run and a
# `require "prism"` in it would be a suite-wide require.
#
# Finds `||` chains that test exactly one set of session states, so a contract
# test can insist the set is asked through its named predicate instead.
#
# The source is parsed rather than grepped: the question is whether code *tests*
# the states, in any order and on any receiver, and a mention in a comment or a
# string is not that.
#
# A chain is judged whole. Ruby groups `||` from the left, so
# `running? || waiting? || needs_input?` holds the sub-chain `running? || waiting?`;
# judging that sub-chain on its own would flag a three-state check as a two-state
# one. A chain that only *contains* the set (`failed? || running? || waiting?`)
# is a superset, a different question, and is not flagged either.
class StatusDisjunctionFinder < Prism::Visitor
  # Every chain in +source+ under +path+ that spells out +states+, as
  # "path:line", except the predicate's own body: an implicit-receiver chain
  # inside `def <predicate_name>` in +predicate_home+.
  #
  # @return [Array<String>]
  def self.offenders(path, source, states:, predicate_name:, predicate_home:)
    finder = new(states)
    Prism.parse(source).value.accept(finder)
    finder.hits
      .reject { |line, def_name, implicit| path == predicate_home && def_name == predicate_name && implicit }
      .map { |line, _, _| "#{path}:#{line}" }
  end

  # Every Ruby file under app/ and lib/, as [relative_path, source].
  def self.app_sources
    root = Rails.root
    Dir[root.join("{app,lib}/**/*.rb")].sort.map do |file|
      [ Pathname(file).relative_path_from(root).to_s, File.read(file) ]
    end
  end

  attr_reader :hits

  def initialize(states)
    @states = states.to_set
    @hits = []
    @current_def = nil
    super()
  end

  def visit_def_node(node)
    outer, @current_def = @current_def, node.name
    super
  ensure
    @current_def = outer
  end

  def visit_or_node(node)
    leaves = flatten(node)
    if leaves.all? { |leaf| state_check?(leaf) } && leaves.map(&:name).to_set == @states
      @hits << [ node.location.start_line, @current_def, leaves.all? { |leaf| leaf.receiver.nil? } ]
    end
    # The nested OrNodes are this same chain; only its leaves can hold another.
    leaves.each { |leaf| leaf.accept(self) }
  end

  private

  def flatten(node)
    node = node.body.body.first while node.is_a?(Prism::ParenthesesNode) && node.body&.body&.size == 1
    return [ node ] unless node.is_a?(Prism::OrNode)

    flatten(node.left) + flatten(node.right)
  end

  def state_check?(node)
    node.is_a?(Prism::CallNode) && node.arguments.nil? && @states.include?(node.name)
  end
end
