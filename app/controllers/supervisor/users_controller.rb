# frozen_string_literal: true

module Supervisor
  class UsersController < Supervisor::ApplicationController
    # The roster of named humans this deployment knows about.
    #
    # Full CRUD, deliberately: this is where a Slack user ID gets linked to a
    # person. Slack IDs are deployment configuration and this repository is
    # public, so the seeded rows ship with none — before this screen existed,
    # turning Slack attribution on meant setting an env var and redeploying,
    # which is why it stayed off.
    #
    # Editing a `key` is the one dangerous action here. HumanMessage#author
    # stores the key verbatim and those records are immutable, so a rename
    # leaves every message that human already authored resolving to nobody (it
    # still renders — falling back to the raw key — but stops naming a person).
    private

    def default_sorting_attribute = :key

    def default_sorting_direction = :asc
  end
end
