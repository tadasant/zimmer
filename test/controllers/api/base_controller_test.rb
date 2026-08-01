require "test_helper"

# Unit coverage for the API's one error envelope (#82). The integration-level
# assertions live in Api::V1::SessionsControllerContractTest; these pin the two
# rescue handlers on Api::BaseController itself, including the RecordInvalid one
# that used to render `message` as an Array.
class Api::BaseControllerTest < ActiveSupport::TestCase
  setup do
    @controller = Api::BaseController.new
  end

  # Capture what the controller would have rendered.
  def rendered(&block)
    payload = nil
    @controller.define_singleton_method(:render) { |args| payload = args }
    block.call
    payload
  end

  test "render_api_error emits a String message and an Array messages" do
    payload = rendered do
      @controller.send(:render_api_error, "Validation failed", [ "a can't be blank", "b is invalid" ], status: :unprocessable_entity)
    end

    assert_equal "Validation failed", payload[:json][:error]
    assert_equal "a can't be blank, b is invalid", payload[:json][:message]
    assert_equal [ "a can't be blank", "b is invalid" ], payload[:json][:messages]
    assert_equal :unprocessable_entity, payload[:status]
  end

  test "render_api_error accepts a bare String" do
    payload = rendered do
      @controller.send(:render_api_error, "Not Found", "nothing here", status: :not_found)
    end

    assert_equal "nothing here", payload[:json][:message]
    assert_equal [ "nothing here" ], payload[:json][:messages]
  end

  test "render_api_error passes extra keys through" do
    payload = rendered do
      @controller.send(:render_api_error, "Rate limited", "slow down", status: :too_many_requests, retry_after: 30)
    end

    assert_equal 30, payload[:json][:retry_after]
    assert_equal "slow down", payload[:json][:message]
  end

  test "the RecordInvalid rescue renders message as a String, not an Array" do
    invalid = Session.new
    invalid.valid?
    exception = ActiveRecord::RecordInvalid.new(invalid)

    payload = rendered { @controller.send(:unprocessable_entity, exception) }

    assert_equal "Unprocessable Entity", payload[:json][:error]
    assert_kind_of String, payload[:json][:message]
    assert_kind_of Array, payload[:json][:messages]
    assert_equal invalid.errors.full_messages, payload[:json][:messages]
    assert_equal invalid.errors.full_messages.join(", "), payload[:json][:message]
  end

  test "the RecordNotFound rescue uses the same envelope" do
    payload = rendered { @controller.send(:not_found) }

    assert_equal "Not Found", payload[:json][:error]
    assert_kind_of String, payload[:json][:message]
    assert_equal [ payload[:json][:message] ], payload[:json][:messages]
  end
end
