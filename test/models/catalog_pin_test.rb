# frozen_string_literal: true

require "test_helper"

class CatalogPinTest < ActiveSupport::TestCase
  test "valid with a github catalog prefix and a ref" do
    pin = CatalogPin.new(catalog: "github://pulsemcp/ai-artifacts", ref: "abc123")
    assert pin.valid?
  end

  test "requires a catalog" do
    pin = CatalogPin.new(ref: "abc123")
    refute pin.valid?
    assert_includes pin.errors[:catalog], "can't be blank"
  end

  test "requires a ref" do
    pin = CatalogPin.new(catalog: "github://pulsemcp/ai-artifacts")
    refute pin.valid?
    assert_includes pin.errors[:ref], "can't be blank"
  end

  test "enforces catalog uniqueness" do
    CatalogPin.create!(catalog: "github://pulsemcp/ai-artifacts", ref: "abc")
    dup = CatalogPin.new(catalog: "github://pulsemcp/ai-artifacts", ref: "def")
    refute dup.valid?
    assert_includes dup.errors[:catalog], "has already been taken"
  end

  test "rejects catalog values that are not bare github://owner/repo" do
    [
      "github://pulsemcp/ai-artifacts/agents",   # has a path
      "github://pulsemcp/ai-artifacts@ref",      # has a ref
      "https://github.com/pulsemcp/ai-artifacts", # wrong scheme
      "pulsemcp/ai-artifacts",                    # no scheme
      "github://pulsemcp"                         # no repo
    ].each do |value|
      pin = CatalogPin.new(catalog: value, ref: "abc")
      refute pin.valid?, "expected #{value.inspect} to be invalid"
    end
  end

  test "accepts SHA, tag, and slashed-branch refs" do
    %w[abc1234 v1.2.3 user/feature-branch main].each do |ref|
      pin = CatalogPin.new(catalog: "github://pulsemcp/ai-artifacts", ref: ref)
      assert pin.valid?, "expected ref #{ref.inspect} to be valid: #{pin.errors.full_messages}"
    end
  end

  test "rejects refs containing whitespace or @" do
    [ "bad ref", "ref@thing", "with\ttab" ].each do |ref|
      pin = CatalogPin.new(catalog: "github://pulsemcp/ai-artifacts", ref: ref)
      refute pin.valid?, "expected ref #{ref.inspect} to be invalid"
    end
  end

  test "as_map returns a catalog => ref hash" do
    CatalogPin.create!(catalog: "github://pulsemcp/ai-artifacts", ref: "abc")
    CatalogPin.create!(catalog: "github://tadasant/zimmer-catalog", ref: "def")

    assert_equal(
      {
        "github://pulsemcp/ai-artifacts" => "abc",
        "github://tadasant/zimmer-catalog" => "def"
      },
      CatalogPin.as_map
    )
  end

  test "as_map is empty when no pins exist" do
    assert_equal({}, CatalogPin.as_map)
  end

  test "fingerprint changes when a pin is added, updated, or removed" do
    base = CatalogPin.fingerprint

    pin = CatalogPin.create!(catalog: "github://pulsemcp/ai-artifacts", ref: "abc")
    after_create = CatalogPin.fingerprint
    refute_equal base, after_create

    pin.update!(ref: "def")
    after_update = CatalogPin.fingerprint
    refute_equal after_create, after_update

    pin.destroy
    after_destroy = CatalogPin.fingerprint
    refute_equal after_update, after_destroy
    assert_equal base, after_destroy
  end
end
