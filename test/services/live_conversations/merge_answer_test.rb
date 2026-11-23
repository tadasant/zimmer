# frozen_string_literal: true

require "test_helper"

module LiveConversations
  class MergeAnswerTest < ActiveSupport::TestCase
    def reader(number: "1490", names: [ "zimmer", "Stop stranded paging" ]) = MergeAnswer.new(number: number, names: names)
    def kind(text, **options) = reader(**options).answer(text).kind

    test "a clear yes, however it is put together" do
      [ "Yes.", "Yes", "Yeah, merge it.", "Go ahead", "yep", "Merge it.", "Do it.", "Uh, yes.", "Okay, merge it", "Great. Merge it",
        "Yes, please", "Yep, approved", "Yeah, that's fine, go ahead", "I already said yes", "Yes Okay, what's next",
        "Yes merge zimmer PR 1,490", "yes, fourteen ninety", "Yes [inhale", "Yes, send it.", "Proceed", "Yes, yes, yes", "Yes, that one, 1490", "Yes, 1490, 1490", "Yes 100%", "Yes, 100 percent", "Yes, I want to merge it",
        "Yes, you can merge it", "Yes, go ahead and merge it into main", "Yes, get it merged", "Sure thing", "Fine by me", "That works, merge it",
        "Yes, thank you very much", "No problem, merge it", "Merge the stranded paging one" ].each do |text|
        assert_equal :yes, kind(text), text
      end
    end

    test "a refusal, a condition or correction, and everything else are told apart" do
      [ "No.", "Nope, leave it", "yes, don’t merge it yet", "Yes, why not", "wait", "Hold on", "No, yeah", "Leave that one", "Pause", "Cant yet", "Actually scratch that",
        "Forget about it", "Yes [no", "Yes [but not yet]" ].each { |text| assert_equal :no, kind(text), text }
      [ "Make sure CI is green first", "merge it after the deploy", "sure but later", "Merge 3601", "Merge thirty six oh one",
        "yes fourteen ninety one", "yes 14901", "the other one", "I'd do it at my laptop", "I take that back", "I changed my mind",
        "Sorry, I meant the docs one" ].each { |text| assert_equal :takes_back, kind(text), text }
      [ "Can you confirm the checks?", "Yes, what's the risk", "What's the weather like?", "Please say that again", "Please merge the docs PR",
        "Okay, one sec.", "Ok so the tests failed", "Sure, tell me more", "ya know", "Yet proved", "Yeah, and what did the gate say",
        "Yes, restart session seven", "Okay, what else does it change?", "Let me think about it", "Give me a minute",
        "Is CI actually green?", "Ok \u{1F44E}", "Yes \u4E0D\u8981", "Yes?" ].each { |text| assert_equal :unclear, kind(text), text }
    end

    test "filler and moving on say nothing about the merge" do
      [ "", "Um", "Hmm", "thanks", "What's next?", "Great, what else is there", "[cough" ].each { |text| assert_equal :neutral, kind(text), text }
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
        "I won't merge it without a yes.", "Merge pull requests 1490 and 1491?", "Checks are green, so want to land PR 1490?",
        "Everything's open and green, want to ship this one?", "Want to ship the one that updates the sweep?", "Should I send it through?",
        "Should I start the merge?", "" ].each { |line| assert_not reader.changes_subject?(line, yes), line }
      [ "Also, want me to restart session 7?", "Also, session 7 is stuck. Should I restart it.", "Or should I wait.", "Restart session seven too.",
        "And merge pull request 1491 as well. Say yes.", "Merge PR fourteen ninety one?", "Would you like to check the logs?", "Want me to check if it's safe to merge?",
        "Want more detail?", "Want to hear why before you merge it?", "Should we wait and merge it tomorrow?", "Merge 1491?", "Merge zimmer 1491?",
        "Ship PR 1491 too?", "Approve pull request 1491?", "Want to land PR 1491?", "Merging pull request 1491, yes?", "Should I email them about the merge?" ].each do |line|
        assert reader.changes_subject?(line, yes), line
      end
      assert reader.changes_subject?("Okay, I won't merge it.", reader.answer("Okay")), "an okay to a no"
    end

    test "a title that reads like an order is not one" do
      named = reader(names: [ "zimmer", "Archive sessions left over" ])
      assert_not named.changes_subject?("archive sessions left over?", named.answer("Yes"))
    end

    test "a question that is merge it? and nothing else" do
      [ "Do you wanna merge it?", "It's green. Merge it?", "CI passes and it's ready to merge. Do you wanna merge it?", "Okay, should I go ahead and merge this one now?",
        "Want to merge it? It's been held since noon." ].each { |line| assert MergeAnswer.asks_only_to_merge?(line), line }
      [ "Should I merge", "Why did the merge gate hold it?", "Merge it? Or wait?", "Merge it or not?", "Want to merge them?", "It's merged.",
        "It's blocking the merge of 12, want to see?", "Want me to check if it's safe to merge?", "Do you want to look at the diff before we merge it?",
        "Want to hear why it won't merge?", "Should we wait and merge it?", "Should I tell the session to fix the conflict so it can merge?" ].each do |line|
        assert_not MergeAnswer.asks_only_to_merge?(line), line
      end
    end
  end
end
