# frozen_string_literal: true

# `validates :goal, goal_reference: true` — refuses a goal that is shaped like a
# catalog id but names no goal in config/goals.json. See GoalsConfig.unknown_id?.
#
# Declared with `if: :will_save_change_to_goal?` on every model that uses it, and
# that condition is load-bearing: a goal id retired from the catalog must not make
# every later save of an old row fail. Only a write that sets the goal is checked.
class GoalReferenceValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    return unless GoalsConfig.unknown_id?(value)

    record.errors.add(attribute, :unknown_goal_id, message: GoalsConfig.unknown_id_reason(value))
  end
end
