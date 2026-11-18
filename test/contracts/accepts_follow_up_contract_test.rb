# frozen_string_literal: true

require "test_helper"
# Prism is a Ruby 3.4 default gem — the same dependency the mocha and ostruct
# contracts lean on.
require "prism"

# "Can this session take a turn?" has one answer, Session#accepts_follow_up?.
#
# Every path that hands a session a turn (the REST and MCP follow-up doors, the
# interrupt service, message_parent's interrupt, the enqueued-message processor,
# trigger reuse, the lost-clone rebuild) asks the same question, and the answer
# is the same three states: running, waiting, needs_input. Spelled out at each
# call site, those copies drift: a new state, or a change to which states take a
# turn, has to be made at every copy, and a copy that is missed answers
# differently from its siblings with nothing to say so.
#
# So no file in app/ or lib/ spells the three-state disjunction out except the
# predicate itself. The source is parsed rather than grepped: the question is
# whether code *tests* the three states, in any order and on any receiver, and a
# mention in a comment or a string is not that.
class AcceptsFollowUpContractTest < ActiveSupport::TestCase
  TURN_TAKING_STATES = %i[running? waiting? needs_input?].to_set.freeze

  # The predicate's own body: `running? || waiting? || needs_input?` with an
  # implicit receiver, in session.rb.
  PREDICATE_HOME = "app/models/session.rb"

  class DisjunctionFinder < Prism::Visitor
    attr_reader :hits

    def initialize
      @hits = []
      super
    end

    def visit_or_node(node)
      leaves = flatten(node)
      if leaves.all? { |leaf| state_check?(leaf) } &&
         leaves.map(&:name).to_set == TURN_TAKING_STATES
        @hits << [ node.location.start_line, leaves.first.receiver.nil? ]
        return # the nested OrNodes are this same chain
      end
      super
    end

    private

    def flatten(node)
      node = node.body.body.first while node.is_a?(Prism::ParenthesesNode) && node.body&.body&.size == 1
      return [ node ] unless node.is_a?(Prism::OrNode)

      flatten(node.left) + flatten(node.right)
    end

    def state_check?(node)
      node.is_a?(Prism::CallNode) && node.arguments.nil? && TURN_TAKING_STATES.include?(node.name)
    end
  end

  def spelled_out_copies(path, source)
    finder = DisjunctionFinder.new
    Prism.parse(source).value.accept(finder)
    finder.hits.reject { |_line, implicit_self| path == PREDICATE_HOME && implicit_self }.map { |line, _| "#{path}:#{line}" }
  end

  test "nothing outside Session#accepts_follow_up? spells out running? || waiting? || needs_input?" do
    root = Rails.root
    offenders = Dir[root.join("{app,lib}/**/*.rb")].sort.flat_map do |file|
      path = Pathname(file).relative_path_from(root).to_s
      spelled_out_copies(path, File.read(file))
    end

    assert_empty offenders,
                 "These spell out the turn-taking states instead of calling Session#accepts_follow_up?:\n" \
                 "#{offenders.join("\n")}"
  end

  test "the finder catches every spelling and leaves partial and unrelated checks alone" do
    flagged = <<~RUBY
      a if s.running? || s.waiting? || s.needs_input?
      b unless s.needs_input? || (s.running? || s.waiting?)
      c = s.waiting? || s.needs_input? || s.running?
    RUBY
    assert_equal %w[x.rb:1 x.rb:2 x.rb:3], spelled_out_copies("x.rb", flagged)

    ignored = <<~RUBY
      a if s.running? || s.waiting?
      b if s.needs_input? || s.waiting? || s.failed?
      # s.running? || s.waiting? || s.needs_input?
      c = "s.running? || s.waiting? || s.needs_input?"
    RUBY
    assert_empty spelled_out_copies("x.rb", ignored)

    assert_empty spelled_out_copies(PREDICATE_HOME, "def accepts_follow_up?\n  running? || waiting? || needs_input?\nend\n")
    assert_equal [ "#{PREDICATE_HOME}:1" ], spelled_out_copies(PREDICATE_HOME, "x if s.running? || s.waiting? || s.needs_input?\n")
  end
end
