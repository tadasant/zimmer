# frozen_string_literal: true

require "test_helper"

# The per-genesis buttons on /inference, limited to the origins no trigger produces.
# The trigger-backed kinds are refused here rather than silently accepted —
# SessionGenesis ignores an override for them on read, so accepting one would be
# a click that appears to work and changes nothing.
class GenesisClassesControllerTest < ActionDispatch::IntegrationTest
  setup do
    AppSetting.editable.update!(genesis_class_overrides: {})
  end

  test "a settable kind moves, and takes its deriving sessions with it" do
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", genesis: SessionGenesis::WEB_UI)
    assert session.priority?

    patch genesis_class_path(genesis: SessionGenesis::WEB_UI, priority_class: SessionGenesis::SPOT)

    assert_redirected_to inference_path(anchor: "spot-gate")
    assert_equal SessionGenesis::SPOT, SessionGenesis.effective_class(SessionGenesis::WEB_UI)
    assert session.reload.spot?, "a class that is derived rather than stored moves with the policy"
  end

  test "a trigger-backed kind is refused and points at the trigger" do
    patch genesis_class_path(genesis: SessionGenesis::SLACK, priority_class: SessionGenesis::SPOT)

    assert_redirected_to inference_path(anchor: "spot-gate")
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

  test "a stale override for a trigger-backed kind is inert" do
    # Nothing writes one any more, but a hand-edited row could still hold one.
    # It must not reclassify that kind's sessions, which is the blast radius the
    # move to the Trigger row exists to remove.
    AppSetting.editable.update_column(:genesis_class_overrides, { SessionGenesis::SLACK => SessionGenesis::SPOT })

    assert_equal SessionGenesis::PRIORITY, SessionGenesis.effective_class(SessionGenesis::SLACK)
  end
end
