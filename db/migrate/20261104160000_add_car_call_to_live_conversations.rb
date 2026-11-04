# frozen_string_literal: true

class AddCarCallToLiveConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :live_conversations, :car_call, :boolean, null: false, default: false
  end
end
