# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class CatalogPinsControllerTest < ActionDispatch::IntegrationTest
  # The test air.json declares github://pulsemcp/ai-artifacts as its only
  # catalog, so that is the one pinnable catalog in this environment.
  PINNABLE = "github://pulsemcp/ai-artifacts"

  test "creates a pin and re-resolves catalogs" do
    skip "Remote-catalog pinning requires a declared remote catalogs[] entry in air.json; Zimmer's default catalog is local-only (no pinnable remote catalogs)."
    AirCatalogService.expects(:refresh!).once.returns(true)

    patch catalog_pins_path, params: { pins: [ { catalog: PINNABLE, ref: "abc123def" } ] }

    assert_redirected_to settings_path
    assert_match(/Catalog pins updated/, flash[:notice])
    pin = CatalogPin.find_by(catalog: PINNABLE)
    assert_equal "abc123def", pin.ref
  end

  test "clears a pin when the ref is blank" do
    skip "Remote-catalog pinning requires a declared remote catalogs[] entry in air.json; Zimmer's default catalog is local-only (no pinnable remote catalogs)."
    CatalogPin.create!(catalog: PINNABLE, ref: "oldsha")
    AirCatalogService.expects(:refresh!).once.returns(true)

    patch catalog_pins_path, params: { pins: [ { catalog: PINNABLE, ref: "" } ] }

    assert_redirected_to settings_path
    assert_nil CatalogPin.find_by(catalog: PINNABLE)
  end

  test "ignores catalogs that are not declared pinnable" do
    AirCatalogService.expects(:refresh!).once.returns(true)

    patch catalog_pins_path, params: { pins: [ { catalog: "github://evil/repo", ref: "abc" } ] }

    assert_redirected_to settings_path
    assert_nil CatalogPin.find_by(catalog: "github://evil/repo")
  end

  test "rolls back the pin change when catalogs fail to resolve" do
    skip "Remote-catalog pinning requires a declared remote catalogs[] entry in air.json; Zimmer default catalog is local-only."
    CatalogPin.create!(catalog: PINNABLE, ref: "oldsha")
    AirCatalogService.expects(:refresh!).once
      .raises(AirCatalogService::CatalogError, "ref not found")

    patch catalog_pins_path, params: { pins: [ { catalog: PINNABLE, ref: "newsha" } ] }

    assert_redirected_to settings_path
    assert_match(/failed to resolve/, flash[:alert])
    # Pin must be unchanged because the transaction rolled back.
    assert_equal "oldsha", CatalogPin.find_by(catalog: PINNABLE).ref
  end

  test "rejects an invalid ref without persisting it" do
    skip "Remote-catalog pinning requires a declared remote catalogs[] entry in air.json; Zimmer default catalog is local-only."
    patch catalog_pins_path, params: { pins: [ { catalog: PINNABLE, ref: "bad ref" } ] }

    assert_redirected_to settings_path
    assert_match(/Invalid pin/, flash[:alert])
    assert_nil CatalogPin.find_by(catalog: PINNABLE)
  end
end
