# frozen_string_literal: true

# The operating-cost taxonomy (functionalities, vendors, accounts) is addressed
# by a stable `key` rather than an id, so the daily collection session can upsert
# the same thing every day without looking ids up first.
module OperatingCostKeyed
  extend ActiveSupport::Concern

  KEY_FORMAT = /\A[a-z0-9][a-z0-9._-]{0,99}\z/

  included do
    validates :key, presence: true, uniqueness: true,
      format: { with: KEY_FORMAT, message: "must be lowercase letters, digits, '.', '_' or '-' (at most 100)" }
  end
end
