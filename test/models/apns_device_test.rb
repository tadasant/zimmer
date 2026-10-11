# frozen_string_literal: true

require "test_helper"

class ApnsDeviceTest < ActiveSupport::TestCase
  test "registering is an upsert that revives a disabled token" do
    device = ApnsDevice.register!(token: "C" * 64, environment: "sandbox", grant: nil, device_name: "Tadas's iPhone")
    device.disable!("BadDeviceToken")

    again = ApnsDevice.register!(token: "c" * 64, environment: "production", grant: nil, app_version: "0.1.0 (7)")

    assert_equal device.id, again.id
    assert_equal "production", again.environment
    assert_nil again.disabled_at
    assert_equal 1, ApnsDevice.count
  end

  test "only hex tokens and known environments are accepted" do
    assert_raises(ActiveRecord::RecordInvalid) { ApnsDevice.register!(token: "not-a-token", environment: "sandbox", grant: nil) }
    assert_raises(ActiveRecord::RecordInvalid) { ApnsDevice.register!(token: "d" * 64, environment: "staging", grant: nil) }
  end
end
