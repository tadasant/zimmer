# frozen_string_literal: true

# Prism is a Ruby 3.4 default gem — the same dependency StatusDisjunctionFinder
# leans on. Required with require_relative by the contract tests that use it, for
# the same reason: a `require "prism"` in test/support would be suite-wide.
require "prism"

# Finds literal lists of exactly one set of session statuses — an array
# (`[ :running, :waiting ]`, `%w[waiting running]`) or the values of a `when`
# clause (`when "running", "waiting"`) — so a contract test can insist the set
# is named through its constant instead.
#
# StatusDisjunctionFinder covers the `running? || waiting?` spelling; this one
# covers the spelling that feeds SQL (`where(status: [...])`), `include?` and
# `case`. Strings and symbols count alike, in any order: ActiveRecord's enum
# takes either in a `where`, and both name the same status.
#
# A list is judged whole, so a list that only *contains* the set
# (`%w[running waiting needs_input]`) is a different question and is not
# flagged. Nor is a list with anything other than plain string and symbol
# elements, such as an interpolated string or a splat: what it holds is not
# known from the source.
#
# Only array literals and `when` lists are read. Other spellings of the same
# set (a pattern-match `in "running" | "waiting"`, `Set[:running, :waiting]`,
# two `where`s joined by `.or`) are not, and none is in app/ or lib/. The
# exemption is by constant name within the home file, not by enclosing class.
class StatusListFinder < Prism::Visitor
  # Every list in +source+ under +path+ that spells out +statuses+, as
  # "path:line", except the constant's own definition: the literal assigned to
  # +constant_name+ in +constant_home+.
  #
  # @return [Array<String>]
  def self.offenders(path, source, statuses:, constant_name:, constant_home:)
    finder = new(statuses)
    Prism.parse(source).value.accept(finder)
    finder.hits
      .reject { |_line, constant| path == constant_home && constant == constant_name }
      .map { |line, _| "#{path}:#{line}" }
  end

  attr_reader :hits

  def initialize(statuses)
    @statuses = statuses.map(&:to_s).sort
    @hits = []
    @constant_values = {}.compare_by_identity
    super()
  end

  # `X = %w[a b].freeze` makes the literal X's whole value; a literal nested
  # deeper in the value (an argument, a hash entry) is not.
  def visit_constant_write_node(node)
    value = node.value
    value = value.receiver if value.is_a?(Prism::CallNode) && value.name == :freeze && value.arguments.nil?
    @constant_values[value] = node.name
    super
  end

  def visit_array_node(node)
    record(node, node.elements)
    super
  end

  def visit_when_node(node)
    record(node, node.conditions)
    super
  end

  private

  def record(node, elements)
    names = elements.map { |element| literal_name(element) }
    return if names.include?(nil) || names.sort != @statuses

    @hits << [ node.location.start_line, @constant_values[node] ]
  end

  def literal_name(node)
    case node
    when Prism::StringNode, Prism::SymbolNode then node.unescaped
    end
  end
end
