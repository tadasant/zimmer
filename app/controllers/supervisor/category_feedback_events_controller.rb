# frozen_string_literal: true

module Supervisor
  class CategoryFeedbackEventsController < Supervisor::ApplicationController
    # The categorization eval corpus, row by row: what the categorizer answered,
    # the context it answered from, what a human said instead, and the last
    # replay verdict. Read-only — the rows are evidence of what a model or a
    # human actually did. Newest first, because the question here is almost
    # always "what happened with the last few".
    private

    def default_sorting_attribute = :id

    def default_sorting_direction = :desc
  end
end
