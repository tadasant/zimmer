# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class CatalogPinsControllerTest < ActionDispatch::IntegrationTest
  # A remote catalog is a *configuration*, not an environment, so these tests
  # declare one rather than waiting for one. `pinnable_catalogs` is the only
  # thing the controller consults and the only thing that reads air.json, so
  # stubbing it is the whole fixture: no network, no token, no catalog repo.
  # Zimmer's own catalog is local-only, which leaves the real value empty — and
  # a test that waits for it to be non-empty never runs at all (#69).
  PINNABLE = "github://pulsemcp/ai-artifacts"

  setup do
    AirCatalogService.stubs(:pinnable_catalogs).returns([ PINNABLE ])
  end

  test "creates a pin and re-resolves catalogs" do
    AirCatalogService.expects(:refresh!).once.returns(true)

    patch catalog_pins_path, params: { pins: [ { catalog: PINNABLE, ref: "abc123def" } ] }

    assert_redirected_to settings_path
    assert_match(/Catalog pins updated/, flash[:notice])
    pin = CatalogPin.find_by(catalog: PINNABLE)
    assert_equal "abc123def", pin.ref
  end

  test "clears a pin when the ref is blank" do
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
    patch catalog_pins_path, params: { pins: [ { catalog: PINNABLE, ref: "bad ref" } ] }

    assert_redirected_to settings_path
    assert_match(/Invalid pin/, flash[:alert])
    assert_nil CatalogPin.find_by(catalog: PINNABLE)
  end
end
