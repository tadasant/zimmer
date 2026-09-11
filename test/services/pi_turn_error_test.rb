# frozen_string_literal: true

require "test_helper"

# What PiTurnError makes of each transcript the real `pi 0.84.4` binary wrote
# when a local provider stub returned that failure (PiSessionFixtures).
class PiTurnErrorTest < ActiveSupport::TestCase
  # --- the transient failures that route to backoff ------------------------------

  test "a 500 is retryable" do
    error = PiTurnError.terminal(pi_session(:server_500))

    assert_equal :retryable, error.kind
    assert error.recognized?
    assert_not error.rate_limited?
    assert_equal 500, error.http_status
    assert_match(/The server had an error while processing your request/, error.message)
  end

  test "a 503 the provider called overloaded is retryable" do
    error = PiTurnError.terminal(pi_session(:overloaded_503))

    assert_equal :retryable, error.kind
    assert_equal 503, error.http_status
  end

  # Pi records `502 <html>…` — a bare space, no colon — because the body is not
  # JSON. Matching on `"NNN: "` would miss the whole class of gateway errors that
  # answer with HTML.
  test "a 502 whose body is not JSON still yields its status" do
    error = PiTurnError.terminal(pi_session(:bad_gateway_502))

    assert_equal :retryable, error.kind
    assert_equal 502, error.http_status
    assert_match(/502 Bad Gateway/, error.message)
  end

  test "a rate-limit 429 is retryable and reads as a rate limit" do
    error = PiTurnError.terminal(pi_session(:rate_limit_429))

    assert_equal :retryable, error.kind
    assert error.rate_limited?
    assert_equal 429, error.http_status
  end

  # Pi's provider has no Zimmer-side account pool to rotate into, so a credit
  # exhaustion takes the same bounded backoff as a rate limit rather than a quota
  # park that nothing would ever wake. See PiAuthProvider.
  test "an insufficient-quota 429 is retryable too, since Pi has no pool to rotate into" do
    error = PiTurnError.terminal(pi_session(:insufficient_quota_429))

    assert_equal :retryable, error.kind
    assert error.rate_limited?
    assert_match(/exceeded your current quota/, error.message)
  end

  test "a stream that closed mid-response is retryable" do
    error = PiTurnError.terminal(pi_session(:stream_terminated))

    assert_equal :retryable, error.kind
    assert_nil error.http_status, "a dropped stream never got a response to carry a status"
    assert_equal "terminated", error.message
  end

  test "a refused connection is retryable" do
    error = PiTurnError.terminal(pi_session(:connection_error))

    assert_equal :retryable, error.kind
    assert_nil error.http_status
    assert_equal "Connection error.", error.message
  end

  # --- the terminal kinds, which are recognized but route nowhere ----------------

  test "a 401 is terminal auth, recognized so it never pages" do
    error = PiTurnError.terminal(pi_session(:unauthorized_401))

    assert_equal :auth_terminal, error.kind
    assert error.recognized?, "a known credential failure is not an unknown failure mode"
    assert_equal 401, error.http_status
  end

  test "a 403 is terminal auth as well" do
    assert_equal :auth_terminal, PiTurnError.terminal(pi_session(:forbidden_403)).kind
  end

  test "a 400 context_length_exceeded is terminal, not a compaction retry" do
    error = PiTurnError.terminal(pi_session(:context_length_400))

    assert_equal :context_length_terminal, error.kind
    assert error.recognized?
    assert_equal 400, error.http_status
  end

  # The evidence for :context_length_terminal: resuming the failed session wrote
  # no compaction record and failed again identically, so there is no recovery to
  # route to. A resumed transcript still classifies on its OWN latest turn.
  test "resuming a context-length failure compacts nothing and stays terminal" do
    serialized = pi_session(:context_length_400_resumed)

    assert_not serialized.include?('"type":"compaction"'),
      "Pi wrote a compaction record on resume — compacts_on_resume? would then be the right answer"

    error = PiTurnError.terminal(serialized)
    assert_equal :context_length_terminal, error.kind
    assert_equal 7, error.line, "the SECOND failure is the terminal one, not the first"
  end

  # --- what is genuinely unknown ------------------------------------------------

  # A 4xx Zimmer has no more specific name for is still a status it READ, so it
  # is recognized: terminal, named, and not an unknown failure mode. Paging on it
  # would mean paging on every provider whose error body Zimmer has not memorized.
  test "a 400 that is not about context length is a recognized rejection, not a page" do
    error = PiTurnError.terminal(pi_session(:bad_request_400))

    assert_equal :request_rejected, error.kind
    assert error.recognized?
    assert_match(/Invalid value for 'temperature'/, error.message)
  end

  # The reason #kind reads the status and not the body: production Pi talks to
  # OpenRouter, whose context-window refusal carries a numeric `"code":400` and
  # no `context_length_exceeded` anywhere. It must still fail quietly rather than
  # page, even though the more precise name is out of reach.
  test "an OpenRouter-shaped context refusal is a recognized rejection, not a page" do
    error = PiTurnError.terminal(pi_session(:openrouter_context_400))

    assert_equal :request_rejected, error.kind
    assert error.recognized?, "an uncharacterized 400 body must not become a standing page"
    assert_equal 400, error.http_status
  end

  test "a 402 is terminal: an exhausted balance does not refill on a backoff" do
    error = PiTurnError.terminal(pi_session(:insufficient_credits_402))

    assert_equal :auth_terminal, error.kind
    assert error.recognized?
    assert_match(/Insufficient credits/, error.message)
  end

  test "a 408 is retryable: the status itself means the request timed out" do
    error = PiTurnError.terminal(pi_session(:timeout_408))

    assert_equal :retryable, error.kind
    assert_equal 408, error.http_status
    assert_not error.rate_limited?
  end

  # A non-HTTP reply and a socket destroyed before any response both collapse to
  # the same `Connection error.` the refused connection produces — the SDK
  # normalizes them, which is why the wording list is two entries and not ten.
  test "a non-HTTP reply is the same transport failure as a refused connection" do
    error = PiTurnError.terminal(pi_session(:connection_error_garbage))

    assert_equal :retryable, error.kind
    assert_equal "Connection error.", error.message
  end

  # Every status class, so a provider dialect Zimmer has not seen still lands
  # somewhere deliberate rather than in the alert.
  test "the status decides, in any dialect" do
    {
      "500: anything at all" => :retryable,
      "599 whatever" => :retryable,
      "429 {}" => :retryable,
      "408: {}" => :retryable,
      "401 {}" => :auth_terminal,
      "402 {}" => :auth_terminal,
      "403 {}" => :auth_terminal,
      "404: not found" => :request_rejected,
      "413: payload too large" => :request_rejected,
      "422 unprocessable" => :request_rejected
    }.each do |text, expected|
      serialized = replace_terminal_message(:unauthorized_401) { |m| m["errorMessage"] = text }

      assert_equal expected, PiTurnError.terminal(serialized).kind, text
    end
  end

  # A status outside 4xx/5xx on a turn Pi called failed is a shape nothing here
  # predicts, and that IS news.
  test "a success status on a failed turn is unclassified" do
    serialized = replace_terminal_message(:unauthorized_401) { |m| m["errorMessage"] = "200: ok?" }

    assert_equal :unclassified, PiTurnError.terminal(serialized).kind
  end

  # The negative case for the context-length match: a 500 whose prose happens to
  # name context_length_exceeded (an upstream router reporting on a sibling
  # request) is a retryable 5xx, not a context-window failure. Driven against the
  # real binary rather than hand-written.
  test "prose naming context_length_exceeded under a 5xx is still a retryable 5xx" do
    serialized = pi_session(:server_500_context_prose)
    assert_includes serialized, "context_length_exceeded"

    error = PiTurnError.terminal(serialized)
    assert_equal :retryable, error.kind
    assert_equal 500, error.http_status
  end

  # The body never overrides the status — it only refines a 400. Even the exact
  # code field under a 5xx stays retryable.
  test "the context-length code under a 5xx does not make it a context failure" do
    serialized = replace_terminal_message(:server_500) do |m|
      m["errorMessage"] = %(503: {"message":"upstream said","code":"context_length_exceeded"})
    end

    assert_equal :retryable, PiTurnError.terminal(serialized).kind
  end

  # --- turns that did not end on an error ---------------------------------------

  test "a completed turn has no terminal error" do
    assert_nil PiTurnError.terminal(pi_session(:completed))
  end

  test "an error Pi retried past on its own is not terminal" do
    assert_nil PiTurnError.terminal(pi_session(:error_then_completed)),
      "the last message is the successful answer, so the turn did not die"
  end

  test "an empty or blank transcript has no terminal error" do
    assert_nil PiTurnError.terminal(nil)
    assert_nil PiTurnError.terminal("")
    assert_nil PiTurnError.terminal("   \n\n")
  end

  test "a transcript with no message records at all has no terminal error" do
    header = pi_session(:completed).lines.first(3).join

    assert_nil PiTurnError.terminal(header)
  end

  # --- record-ordering and malformed-line tolerance ------------------------------

  # Pi appends `model_change` / `thinking_level_change` around messages. A
  # trailing one must not hide the error the turn actually died on.
  test "trailing bookkeeping records do not make a terminal error look non-terminal" do
    serialized = pi_session(:unauthorized_401) +
      %({"type":"model_change","id":"ffffffff","parentId":"6d5e2e92","timestamp":"2026-09-11T20:34:17.000Z","provider":"sim","modelId":"sim-model"}\n)

    assert_equal :auth_terminal, PiTurnError.terminal(serialized).kind
  end

  # The last line of a transcript a live `pi` is still writing is routinely
  # half-flushed. Reading that as "no error" would call a dead turn a live one.
  test "a half-flushed final line is skipped, not read as the absence of an error" do
    serialized = pi_session(:server_500) + %({"type":"message","id":"partial","mess)

    error = PiTurnError.terminal(serialized)
    assert_equal :retryable, error.kind
  end

  test "a malformed line in the middle is skipped" do
    lines = pi_session(:server_500).lines
    lines.insert(-2, "{not json at all\n")

    assert_equal :retryable, PiTurnError.terminal(lines.join).kind
  end

  test "a JSON line that is not an object is skipped" do
    serialized = pi_session(:server_500) + "[1,2,3]\n"

    assert_equal :retryable, PiTurnError.terminal(serialized).kind
  end

  # --- identity, which is what stops one dead turn being acted on twice ----------

  test "the id is Pi's own record id" do
    error = PiTurnError.terminal(pi_session(:unauthorized_401))
    record_id = JSON.parse(pi_session(:unauthorized_401).lines.last)["id"]

    assert_equal record_id, error.id
    assert_equal 5, error.line
  end

  test "a record written without an id falls back to its line number" do
    serialized = pi_session(:unauthorized_401).lines.map do |line|
      record = JSON.parse(line)
      record.delete("id") if record["type"] == "message"
      "#{JSON.generate(record)}\n"
    end.join

    assert_equal "line:5", PiTurnError.terminal(serialized).id
  end

  # --- shapes that are an error record but not a usable one ---------------------

  test "an error record with a blank errorMessage is not a terminal error" do
    serialized = replace_terminal_message(:unauthorized_401) { |m| m["errorMessage"] = "" }

    assert_nil PiTurnError.terminal(serialized)
  end

  test "an assistant message with a non-error stopReason is not a terminal error" do
    serialized = replace_terminal_message(:unauthorized_401) { |m| m["stopReason"] = "stop" }

    assert_nil PiTurnError.terminal(serialized)
  end

  test "a message record whose message is not an object is not a terminal error" do
    lines = pi_session(:unauthorized_401).lines
    record = JSON.parse(lines.last).merge("message" => "not an object")
    serialized = (lines[0..-2] + [ "#{JSON.generate(record)}\n" ]).join

    assert_nil PiTurnError.terminal(serialized)
  end

  # The one shape that pages: no status Zimmer could read, and no transport
  # wording it knows. That is the alert doing its job — the signal to characterize
  # the wording and add it.
  test "an unprefixed error message with no known transport wording is unclassified" do
    serialized = replace_terminal_message(:unauthorized_401) do |m|
      m["errorMessage"] = "The provider melted."
    end

    error = PiTurnError.terminal(serialized)
    assert_equal :unclassified, error.kind
    assert_not error.recognized?
    assert_nil error.http_status
  end

  # The transport match is anchored to the whole message, so a provider error
  # that merely contains the word is not mistaken for one.
  test "a message that merely mentions a transport wording is not a transport failure" do
    serialized = replace_terminal_message(:unauthorized_401) do |m|
      m["errorMessage"] = "the upstream worker terminated the job"
    end

    assert_equal :unclassified, PiTurnError.terminal(serialized).kind
  end

  # A leading newline must not cost the status, or a 500 would stop being retried.
  test "a status behind leading whitespace is still read" do
    serialized = replace_terminal_message(:server_500) do |m|
      m["errorMessage"] = "\n  500: {\"message\":\"boom\"}"
    end

    error = PiTurnError.terminal(serialized)
    assert_equal 500, error.http_status
    assert_equal :retryable, error.kind
  end

  # Digits that are not a status prefix must not be read as one — `4000: …` is
  # four digits, and `401abc` has no delimiter after the third.
  test "leading digits that are not a three-digit status are not a status" do
    [ "4000: something went wrong", "401abc: not a status", "40: short" ].each do |text|
      serialized = replace_terminal_message(:unauthorized_401) { |m| m["errorMessage"] = text }

      assert_nil PiTurnError.terminal(serialized).http_status, "#{text.inspect} is not a status"
    end
  end

  private

  # The fixture with its terminal assistant message mutated in place by the block.
  def replace_terminal_message(name)
    lines = pi_session(name).lines
    record = JSON.parse(lines.last)
    yield(record["message"])
    (lines[0..-2] + [ "#{JSON.generate(record)}\n" ]).join
  end
end
