require "test_helper"
require "mocha/minitest"

# Tests for the read-side interleaving of the dashboard sections: SessionsController#index
# builds @ordered_sections by sorting custom categories together with the special
# "Uncategorized" bucket, using AppSetting#uncategorized_position as Uncategorized's slot.
# These assert the rendered top-to-bottom order of [data-category-section-id] values.
class SessionsControllerCategoryOrderTest < ActionDispatch::IntegrationTest
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.any_instance.stubs(:broadcast_remove_from_sessions_index)

    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all
    Category.delete_all
    AppSetting.delete_all
  end

  # Pull the rendered section ids in document order so we can assert the stack layout.
  def rendered_section_ids
    css_select("#category_sections [data-category-section-id]").map { |el| el["data-category-section-id"] }
  end

  test "fresh install renders Uncategorized at the top of the stack" do
    # No AppSetting row: uncategorized_position falls back to the schema default 0, and
    # the tie-break ranks Uncategorized ahead of an equal-position category.
    a = Category.create!(name: "A", position: 0)
    b = Category.create!(name: "B", position: 1)

    get root_path

    assert_response :success
    assert_equal [ "uncategorized", a.id.to_s, b.id.to_s ], rendered_section_ids
  end

  test "Uncategorized interleaves at its persisted position" do
    a = Category.create!(name: "A", position: 0)
    b = Category.create!(name: "B", position: 1)
    AppSetting.create!(uncategorized_position: 1)

    get root_path

    assert_response :success
    # Position 1 places Uncategorized after A (pos 0) and before B (pos 1); the tie-break
    # with B at equal position keeps Uncategorized first.
    assert_equal [ a.id.to_s, "uncategorized", b.id.to_s ], rendered_section_ids
  end

  test "Uncategorized can render at the bottom of the stack" do
    a = Category.create!(name: "A", position: 0)
    b = Category.create!(name: "B", position: 1)
    AppSetting.create!(uncategorized_position: 2)

    get root_path

    assert_response :success
    assert_equal [ a.id.to_s, b.id.to_s, "uncategorized" ], rendered_section_ids
  end
end
