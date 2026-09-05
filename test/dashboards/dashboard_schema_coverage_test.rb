require "test_helper"

# The /supervisor dashboards are the generic, no-shell view of Zimmer's own database, and
# they are hand-maintained scaffold. Administrate does not raise when ATTRIBUTE_TYPES is
# missing a column — it silently renders the page without it, so a panel showing 15 of 38
# columns looks exactly like a complete one. That is the failure mode this test exists for:
# a migration that adds a column now fails here until someone decides, in the same PR,
# whether the column belongs on the panel or in that dashboard's DELIBERATELY_OMITTED list.
#
# Scope: this governs ATTRIBUTE_TYPES only. COLLECTION_ATTRIBUTES / SHOW_PAGE_ATTRIBUTES /
# FORM_ATTRIBUTES stay a judgement call — the panel is editable, so what is writable through
# a generic form is a decision, and a multi-megabyte column on an index page is a slow page.
class DashboardSchemaCoverageTest < ActiveSupport::TestCase
  DASHBOARD_PATHS = Rails.root.glob("app/dashboards/*_dashboard.rb").sort.freeze

  test "every dashboard file resolves to a dashboard class and a model" do
    assert_predicate DASHBOARD_PATHS, :any?, "expected app/dashboards to hold dashboards"

    DASHBOARD_PATHS.each do |path|
      dashboard = dashboard_class_for(path)
      assert_kind_of Class, dashboard, "#{path.basename} does not define #{dashboard_name_for(path)}"
      assert_operator dashboard, :<, Administrate::BaseDashboard,
        "#{dashboard} should inherit from Administrate::BaseDashboard"

      model = model_class_for(dashboard)
      refute_nil model, "#{dashboard} has no model — #{model_name_for(dashboard)} does not exist"
      assert_respond_to model, :column_names, "#{model_name_for(dashboard)} is not an ActiveRecord model"
    end
  end

  test "every dashboard covers every column of its model" do
    drifted = {}

    DASHBOARD_PATHS.each do |path|
      dashboard = dashboard_class_for(path)
      model = model_class_for(dashboard)
      next if model.nil? || !model.respond_to?(:column_names)

      missing = model.column_names - covered_columns(dashboard, model)
      drifted[dashboard.name] = missing if missing.any?
    end

    assert_empty drifted, <<~MESSAGE
      These dashboards omit columns that exist in db/schema.rb. Administrate will not
      raise — it just renders the panel without them. For each column, either add it to
      the dashboard's ATTRIBUTE_TYPES, or add it to that dashboard's DELIBERATELY_OMITTED
      with a comment saying why it is not rendered.

      #{drifted.map { |name, cols| "  #{name} (#{cols.size}): #{cols.join(', ')}" }.join("\n")}
    MESSAGE
  end

  test "DELIBERATELY_OMITTED only names columns that exist" do
    stale = {}

    DASHBOARD_PATHS.each do |path|
      dashboard = dashboard_class_for(path)
      next unless dashboard.const_defined?(:DELIBERATELY_OMITTED, false)

      model = model_class_for(dashboard)
      next if model.nil? || !model.respond_to?(:column_names)

      unknown = dashboard::DELIBERATELY_OMITTED.map(&:to_s) - model.column_names
      stale[dashboard.name] = unknown if unknown.any?
    end

    assert_empty stale, <<~MESSAGE
      These dashboards list DELIBERATELY_OMITTED entries that are not columns on the model.
      The column was probably renamed or dropped; drop the entry too.

      #{stale.map { |name, cols| "  #{name}: #{cols.join(', ')}" }.join("\n")}
    MESSAGE
  end

  test "DELIBERATELY_OMITTED does not repeat what ATTRIBUTE_TYPES already renders" do
    contradictory = {}

    DASHBOARD_PATHS.each do |path|
      dashboard = dashboard_class_for(path)
      next unless dashboard.const_defined?(:DELIBERATELY_OMITTED, false)

      both = dashboard::DELIBERATELY_OMITTED.map(&:to_s) & dashboard::ATTRIBUTE_TYPES.keys.map(&:to_s)
      contradictory[dashboard.name] = both if both.any?
    end

    assert_empty contradictory, <<~MESSAGE
      These dashboards both render a column and list it as deliberately omitted. Pick one.

      #{contradictory.map { |name, cols| "  #{name}: #{cols.join(', ')}" }.join("\n")}
    MESSAGE
  end

  private

  # A column counts as covered when the dashboard names it directly, when it is the
  # foreign key behind an association the dashboard renders (`batch: Field::BelongsTo`
  # covers `outcome_analysis_batch_id`), or when the dashboard has written down why it
  # is not there.
  def covered_columns(dashboard, model)
    attributes = dashboard::ATTRIBUTE_TYPES.keys

    foreign_keys = attributes.filter_map do |attribute|
      reflection = model.reflect_on_association(attribute)
      reflection.foreign_key.to_s if reflection&.belongs_to?
    end

    omitted = dashboard.const_defined?(:DELIBERATELY_OMITTED, false) ? dashboard::DELIBERATELY_OMITTED : []

    attributes.map(&:to_s) + foreign_keys + omitted.map(&:to_s)
  end

  def dashboard_name_for(path)
    path.basename(".rb").to_s.camelize
  end

  def dashboard_class_for(path)
    dashboard_name_for(path).constantize
  end

  def model_name_for(dashboard)
    dashboard.name.delete_suffix("Dashboard")
  end

  def model_class_for(dashboard)
    model_name_for(dashboard).constantize
  rescue NameError
    nil
  end
end
