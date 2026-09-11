# frozen_string_literal: true

module Workflow
  # One declared input — what ApplicationWorkflow.param records.
  #
  # It is both the descriptor a param form will be rendered from and the source
  # Workflow::Input derives its validation from, which is why the presentation
  # fields live here even though no form renders them.
  class Param < Data.define(:key, :type, :required, :label, :help, :widget, :example, :options)
  end
end
