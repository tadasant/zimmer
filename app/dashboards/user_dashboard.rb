require "administrate/base_dashboard"

class UserDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    key: Field::String,
    display_name: Field::String,
    email: Field::String,
    # Administrate has no array field, so the Postgres array is displayed and
    # edited through its comma-separated view. `sorting_column` points the index
    # header back at the real column, which is what can actually be ordered by.
    slack_user_ids_list: Field::String.with_options(searchable: false, sorting_column: :slack_user_ids),
    notes: Field::Text,
    human_messages: Field::HasMany.with_options(limit: 5),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # DELIBERATELY_OMITTED
  # columns that exist on the table and are intentionally not rendered here.
  # test/dashboards/dashboard_schema_coverage_test.rb reads this, so an omission
  # is a reviewed decision rather than a gap nobody noticed.
  DELIBERATELY_OMITTED = [
    # Rendered and edited through `slack_user_ids_list` above — Administrate has
    # no array field, so the Postgres array is shown in its comma-separated view.
    # The raw column would be a second, conflicting editor for the same data.
    :slack_user_ids
  ].freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  COLLECTION_ATTRIBUTES = %i[
    key
    display_name
    email
    slack_user_ids_list
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    key
    display_name
    email
    slack_user_ids_list
    notes
    human_messages
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  #
  # This is the surface that exists so Slack attribution can be switched on
  # without a deploy: a Slack user ID is deployment configuration, this
  # repository is public, and the seeded rows ship with an empty list.
  #
  # `key` is editable but should not be edited casually — HumanMessage#author
  # stores it verbatim, so changing it orphans every record that human has
  # already authored.
  FORM_ATTRIBUTES = %i[
    key
    display_name
    email
    slack_user_ids_list
    notes
  ].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  COLLECTION_FILTERS = {
    slack_linked: ->(resources) { resources.where("slack_user_ids <> '{}'") }
  }.freeze

  def display_resource(user)
    "#{user.display_name} (#{user.key})"
  end
end
