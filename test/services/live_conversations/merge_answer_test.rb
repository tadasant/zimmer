# frozen_string_literal: true

require "test_helper"

module LiveConversations
  class MergeAnswerTest < ActiveSupport::TestCase
    def reader(number: "1490", names: [ "zimmer", "Stop stranded paging" ]) = MergeAnswer.new(number: number, names: names)
    def kind(text, **options) = reader(**options).answer(text).kind

    test "a clear yes, however it is put together" do
      [ "Yes.", "Yes", "Yeah, merge it.", "Go ahead", "yep", "Merge it.", "Do it.", "Uh, yes.", "Okay, merge it", "Great. Merge it",
        "Yes, please", "Yep, approved", "Yeah, that's fine, go ahead", "I already said yes", "Yes Okay, what's next",
        "Yes merge zimmer PR 1,490", "yes, fourteen ninety", "Yes [inhale", "Yes, send it.", "Proceed", "Yes, yes, yes", "Merge the stranded paging one" ].each do |text|
        assert_equal :yes, kind(text), text
      end
    end

    test "a refusal, a condition or correction, and everything else are told apart" do
      [ "No.", "Nope, leave it", "yes, don’t merge it yet", "Yes, why not", "wait", "Hold on", "No, yeah" ].each { |text| assert_equal :no, kind(text), text }
      [ "Make sure CI is green first", "merge it after the deploy", "sure but later", "Merge 3601", "Merge thirty six oh one",
        "yes fourteen ninety one", "yes 14901", "the other one", "I wanna do it at my laptop" ].each { |text| assert_equal :takes_back, kind(text), text }
      [ "Can you confirm the checks?", "Yes, what's the risk", "What's the weather like?", "Hmm", "Please say that again", "Please merge the docs PR",
        "Okay, one sec.", "Ok so the tests failed", "Sure, tell me more", "ya know", "Yet proved", "Yeah, and what did the gate say",
        "Yes, restart session seven", "" ].each { |text| assert_equal :unclear, kind(text), text }
    end

    test "the person naming this PR by its spoken number is not a correction, whatever the number" do
      { "3600" => "thirty six hundred", "3605" => "three thousand six hundred and five", "1405" => "fourteen oh five", "7" => "seven",
        "3760" => "three seven six zero" }.each do |number, spoken|
        assert_equal :yes, kind("Yes, merge pull request #{spoken}", number: number), spoken
      end
      assert_equal :takes_back, kind("yes 12 and 34", number: "1234")
    end

    test "an assistant line changes the subject only when it recognisably does" do
      yes = reader.answer("Yes")
      [ "Say yes, and I'll do it.", "the one that stops stranded", "paging?", "Merge zimmer pull request", "Okay, merging.", "Checking for the next one.",
        "Want me to go ahead?", "Should I land it or hold it?", "Merge zimmer pull request 1490, \"Archive old sessions\"?", "Stop stranded paging?",
        "It follows up pull request 1480. Want to merge it?", "Merge pull request fourteen", "Merge pull request 1 4 9 0?", "It didn't go through yet, sorry.",
        "I won't merge it without a yes.", "Merge pull requests 1490 and 1491?", "" ].each { |line| assert_not reader.changes_subject?(line, yes), line }
      [ "Also, want me to restart session 7?", "Also, session 7 is stuck. Should I restart it.", "Or should I wait.", "Restart session seven too.",
        "And merge pull request 1491 as well. Say yes.", "Merge PR fourteen ninety one?", "Would you like to check the logs?" ].each do |line|
        assert reader.changes_subject?(line, yes), line
      end
      assert reader.changes_subject?("Okay, I won't merge it.", reader.answer("Okay")), "an okay to a no"
    end

    test "a title that reads like an order is not one" do
      named = reader(names: [ "zimmer", "Archive sessions left over" ])
      assert_not named.changes_subject?("archive sessions left over?", named.answer("Yes"))
    end

    test "asking to merge one PR" do
      [ "Do you wanna merge it?", "It's green. Merge zimmer PR 1490?", "Want to merge it? It's been held since noon." ].each { |line| assert MergeAnswer.asks_to_merge?(line), line }
      [ "Should I merge", "Why did the merge gate hold it?", "Merge it? Or wait?", "Merge it or not?", "Want to merge them?", "It's merged.",
        "It's blocking the merge of 12, want to see?" ].each { |line| assert_not MergeAnswer.asks_to_merge?(line), line }
    end
  end
end
