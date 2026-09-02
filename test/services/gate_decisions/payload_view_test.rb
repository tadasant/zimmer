# frozen_string_literal: true

require "test_helper"

# The renderer's whole contract is that it never needs to have seen a key before.
# These tests are written the way the view is: about SHAPES, never about the
# names the gates happen to use today.
class GateDecisions::PayloadViewTest < ActiveSupport::TestCase
  def kind_of(payload, key)
    GateDecisions::PayloadView.new(payload).fields.find { |f| f.key == key }&.kind
  end

  test "classifies by shape, not by key name" do
    view = GateDecisions::PayloadView.new(
      "decision" => "hold",
      "aligned" => true,
      "score" => 3,
      "pr" => "https://github.com/tadasant/zimmer/pull/781",
      "reason" => "x" * 500,
      "facets" => [ "subtractive", "additive" ],
      "ratings" => { "impact" => "medium" },
      "disclosures" => [ { "kind" => "note", "body" => "y" } ],
      "missing" => nil,
      "empty_list" => [],
      "empty_map" => {}
    )
    kinds = view.fields.to_h { |f| [ f.key, f.kind ] }

    assert_equal :text, kinds["decision"]
    assert_equal :boolean, kinds["aligned"]
    assert_equal :number, kinds["score"]
    assert_equal :url, kinds["pr"]
    assert_equal :prose, kinds["reason"]
    assert_equal :chips, kinds["facets"]
    assert_equal :object, kinds["ratings"]
    assert_equal :list, kinds["disclosures"]
    assert_equal :blank, kinds["missing"]
    assert_equal :blank, kinds["empty_list"]
    assert_equal :blank, kinds["empty_map"]
  end

  test "a multi-line string is prose even when it is short" do
    assert_equal :prose, kind_of({ "note" => "one\ntwo" }, "note")
  end

  test "a long string inside an array is not a chip" do
    # `hold_tests` is a list of one-liners and renders as chips; a list of
    # paragraphs must not, or the page turns into an unreadable chip wall.
    assert_equal :chips, kind_of({ "hold_tests" => [ "ci green", "no conflicts" ] }, "hold_tests")
    assert_equal :list, kind_of({ "hold_tests" => [ "x" * 500 ] }, "hold_tests")
  end

  test "an unknown key with a shape it has never seen still renders, and is not dropped" do
    # THE REGRESSION THIS FILE EXISTS FOR. The gates add keys — four arrived in
    # the last few weeks of the corpus — and a view that quietly omits one is
    # worse than one that crashes, because nobody finds out.
    payload = {
      "reason" => "held it",
      "some_key_invented_next_month" => { "nested" => [ 1, 2, { "deep" => true } ] }
    }
    view = GateDecisions::PayloadView.new(payload)

    assert_equal %w[reason some_key_invented_next_month], view.fields.map(&:key)
    assert_equal :object, kind_of(payload, "some_key_invented_next_month")
  end

  test "nesting past the depth cap degrades to JSON rather than to nothing" do
    deep = { "a" => { "b" => { "c" => { "d" => { "e" => { "f" => "too far" } } } } } }
    field = GateDecisions::PayloadView.new(deep).fields.sole

    # Walk to the field that hit the cap and check it still carries its value —
    # the view prints it as JSON rather than dropping it.
    node = field
    node = node.children.sole while node.children.present?
    assert_equal :json, node.kind
    assert_equal({ "f" => "too far" }, node.value)
  end

  test "glance takes what skims and leaves the paragraphs behind" do
    view = GateDecisions::PayloadView.new(
      "decision" => "hold",
      "ratings" => { "impact" => "medium", "risk" => "large" },
      "justifications" => { "impact" => "z" * 400 },
      "reason" => "y" * 900
    )

    # `ratings` and `justifications` carry the same keys and the same nesting.
    # One skims and the other does not, and no rule naming either was needed.
    assert_equal %w[decision ratings], view.glance.map(&:key)
    assert_equal %w[reason], view.prose_fields.map(&:key)
  end

  test "glance may pick but fields never omits, in the order the gate wrote them" do
    payload = { "reason" => "y" * 900, "decision" => "hold", "ratings" => { "impact" => "small" } }

    assert_equal %w[reason decision ratings], GateDecisions::PayloadView.new(payload).fields.map(&:key)
  end

  test "a blank field is offered by fields and withheld from glance" do
    view = GateDecisions::PayloadView.new("issue" => nil, "decision" => "hold")

    assert_equal %w[issue decision], view.fields.map(&:key), "the entry view shows an absent field as absent"
    assert_equal %w[decision], view.glance.map(&:key), "the glance panel does not fill up with em dashes"
  end

  test "a payload that is not a Hash is empty rather than an exception" do
    assert_empty GateDecisions::PayloadView.new(nil).fields
    assert_empty GateDecisions::PayloadView.new("a string").fields
    assert_not GateDecisions::PayloadView.new({}).any?
  end

  test "labels humanize a key without rewriting it, and anchors are usable" do
    field = GateDecisions::PayloadView.new("staleness_check" => "live").fields.sole

    assert_equal "Staleness check", field.label
    assert_equal "entry-staleness-check", field.anchor
  end

  test "a key that humanizes to nothing still gets a label and an anchor" do
    field = GateDecisions::PayloadView.new("_" => "x").fields.sole

    assert_equal "_", field.label
    assert_equal "entry-field", field.anchor
  end
end
