# frozen_string_literal: true

module Mcp
  # Cutting text down to a size a tool result can actually carry — and saying so.
  #
  # Every cut made on this surface is announced. A result that quietly drops the
  # tail of a value is indistinguishable from one where the value ended there,
  # so a caller reading a record to answer "is there anything here?" cannot tell
  # "no" from "yes, and you did not ask for it" (#652). The helpers therefore
  # come in a pair: one that cuts, one that states what was cut, how long the
  # original was, and which call returns the rest.
  module TextBudget
    module_function

    # Deliberately NOT String#truncate: `limit` here is how much of the text
    # survives, and the ellipsis is added on top rather than counted against it,
    # so a limit of 1000 always yields 1000 characters of content.
    def hard_truncate(text, limit)
      text = text.to_s
      text.length > limit ? "#{text[0, limit]}..." : text
    end

    def over?(text, limit)
      text.to_s.length > limit
    end

    # The sentence that travels with a cut value. `restore` names the call that
    # returns the full text — never omitted, because "there is more" is only
    # useful next to "and here is how to get it".
    def truncation_note(shown:, total:, restore:)
      "_Truncated: #{delimited(shown)} of #{delimited(total)} characters shown. #{restore}_"
    end

    def delimited(number)
      ActiveSupport::NumberHelper.number_to_delimited(number)
    end
  end
end
