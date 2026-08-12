# frozen_string_literal: true

require "test_helper"

# The per-genesis buttons on /settings, now limited to the origins no trigger
# produces. The trigger-backed kinds are refused here rather than silently
# accepted — SessionGenesis ignores an override for them on read, so accepting
# one would be a click that appears to work and changes nothing.
class GenesisClassesControllerTest < ActionDispatch::IntegrationTest
  setup do
    AppSetting.editable.update!(genesis_class_overrides: {})
  end

  test "a settable kind moves, and takes its deriving sessions with it" do
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", genesis: SessionGenesis::WEB_UI)
    assert session.priority?

    patch genesis_class_path(genesis: SessionGenesis::WEB_UI, priority_class: SessionGenesis::SPOT)

    assert_redirected_to settings_path(anchor: "spot-gate")
    assert_equal SessionGenesis::SPOT, SessionGenesis.effective_class(SessionGenesis::WEB_UI)
    assert session.reload.spot?, "a class that is derived rather than stored moves with the policy"
  end

  test "a trigger-backed kind is refused and points at the trigger" do
    patch genesis_class_path(genesis: SessionGenesis::SLACK, priority_class: SessionGenesis::SPOT)

    assert_redirected_to settings_path(anchor: "spot-gate")
    assert_match(/takes its class from the trigger/, flash[:alert])
    assert_equal({}, AppSetting.current.genesis_class_overrides)
  end

  test "an unknown genesis is refused" do
    patch genesis_class_path(genesis: "carrier_pigeon", priority_class: SessionGenesis::SPOT)
    assert_match(/Unknown genesis/, flash[:alert])
  end

  test "an unknown class is refused" do
    patch genesis_class_path(genesis: SessionGenesis::WEB_UI, priority_class: "urgent")
    assert_match(/Unknown class/, flash[:alert])
  end

  test "reset returns every settable kind to its default" do
    patch genesis_class_path(genesis: SessionGenesis::WEB_UI, priority_class: SessionGenesis::SPOT)

    delete reset_genesis_classes_path

    assert_equal({}, AppSetting.current.genesis_class_overrides)
    assert_equal SessionGenesis::PRIORITY, SessionGenesis.effective_class(SessionGenesis::WEB_UI)
  end

  test "a stale override for a trigger-backed kind is pruned on the next write" do
    # Written before the selector moved to Trigger. It is already inert on read;
    # this makes sure it does not linger in the column to mislead the next reader.
    setting = AppSetting.editable
    setting.update_column(:genesis_class_overrides, { SessionGenesis::SLACK => SessionGenesis::SPOT })

    patch genesis_class_path(genesis: SessionGenesis::WEB_UI, priority_class: SessionGenesis::SPOT)

    assert_equal({ SessionGenesis::WEB_UI => SessionGenesis::SPOT }, AppSetting.current.genesis_class_overrides)
  end
end
