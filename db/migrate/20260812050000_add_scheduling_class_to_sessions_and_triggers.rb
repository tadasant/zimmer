# frozen_string_literal: true

# Moves the spot/priority selector off the global per-genesis-kind setting and
# onto the two rows that actually carry the decision: the trigger that spawns a
# session, and the session itself.
#
# Both columns are nullable, and NULL keeps its old meaning — "no one has said
# anything, derive the class from the genesis". Only a deliberate choice is
# stored, so the shipped defaults stay live rather than being frozen into every
# row at creation.
class AddSchedulingClassToSessionsAndTriggers < ActiveRecord::Migration[8.0]
  def up
    add_column :sessions, :scheduling_class, :string
    add_column :triggers, :scheduling_class, :string
    add_index :sessions, :scheduling_class, where: "scheduling_class IS NOT NULL"

    migrate_trigger_backed_overrides!
  end

  def down
    restore_trigger_backed_overrides!

    remove_index :sessions, column: :scheduling_class, where: "scheduling_class IS NOT NULL"
    remove_column :triggers, :scheduling_class
    remove_column :sessions, :scheduling_class
  end

  private

  # Five of the eight genesis kinds are restatements of trigger condition types.
  # Their per-kind overrides move down onto every trigger that derives that kind,
  # so an operator who had demoted `slack` keeps exactly the triggers they had
  # demoted — one row at a time now, rather than all of them at once.
  TRIGGER_BACKED = {
    "slack" => "slack",
    "github_issue" => "github_issue",
    "github_label" => "github_label",
    "schedule" => "schedule",
    "ao_event" => "ao_event"
  }.freeze

  # The kind a trigger's sessions derive, when it carries several condition types.
  PRECEDENCE = %w[slack github_label github_issue ao_event schedule].freeze

  def migrate_trigger_backed_overrides!
    setting = select_one("SELECT id, genesis_class_overrides FROM app_settings ORDER BY id LIMIT 1")
    return if setting.nil?

    overrides = parse_overrides(setting["genesis_class_overrides"])
    moved = overrides.slice(*TRIGGER_BACKED.keys)
    return if moved.empty?

    each_trigger_kind do |trigger_id, kind|
      klass = moved[kind]
      next if klass.blank?

      execute("UPDATE triggers SET scheduling_class = #{quote(klass)} WHERE id = #{trigger_id.to_i}")
    end

    remaining = overrides.except(*TRIGGER_BACKED.keys)
    execute(
      "UPDATE app_settings SET genesis_class_overrides = #{quote(remaining.to_json)}::jsonb " \
      "WHERE id = #{setting['id'].to_i}"
    )
  end

  # Rolling back folds each trigger's class back up into the per-kind setting.
  # Lossy by nature — per-trigger choices collapse to one value per kind — so the
  # winner is whatever the majority of that kind's triggers carry.
  def restore_trigger_backed_overrides!
    setting = select_one("SELECT id, genesis_class_overrides FROM app_settings ORDER BY id LIMIT 1")
    return if setting.nil?

    by_kind = Hash.new { |h, k| h[k] = [] }
    each_trigger_kind do |trigger_id, kind|
      klass = select_value("SELECT scheduling_class FROM triggers WHERE id = #{trigger_id.to_i}")
      by_kind[kind] << klass if klass.present?
    end
    return if by_kind.empty?

    overrides = parse_overrides(setting["genesis_class_overrides"])
    by_kind.each { |kind, classes| overrides[kind] = classes.tally.max_by { |_c, n| n }.first }
    execute(
      "UPDATE app_settings SET genesis_class_overrides = #{quote(overrides.to_json)}::jsonb " \
      "WHERE id = #{setting['id'].to_i}"
    )
  end

  # Yields [trigger_id, genesis_kind] for every trigger that has at least one
  # condition mapping to a trigger-backed kind.
  def each_trigger_kind
    rows = select_all(
      "SELECT trigger_id, condition_type FROM trigger_conditions WHERE trigger_id IS NOT NULL"
    ).to_a
    rows.group_by { |r| r["trigger_id"] }.each do |trigger_id, conditions|
      types = conditions.map { |c| c["condition_type"].to_s }
      winner = PRECEDENCE.find { |t| types.include?(t) }
      next if winner.nil?

      yield trigger_id, TRIGGER_BACKED.fetch(winner)
    end
  end

  def parse_overrides(raw)
    parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end
end
