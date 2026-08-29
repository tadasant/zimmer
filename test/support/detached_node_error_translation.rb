# frozen_string_literal: true

require "capybara"
require "capybara/selenium/nodes/chrome_node"

# Chrome misreports a node that left the document, and Capybara cannot retry an
# error it does not recognize.
#
# Why this exists
# ---------------
# Every Capybara query resolves candidate elements and *then* asks the browser
# about each one — "is it displayed?" — as a separate round trip. If the document
# is replaced in between, the handle Capybara is holding no longer belongs to a
# document. WebDriver's answer for that is `StaleElementReferenceError`, which
# Capybara lists in `invalid_element_errors`; its `synchronize` loop swallows
# those and retries by re-resolving against the page that exists now. That retry
# is the whole reason a Capybara suite tolerates a re-rendering page at all.
#
# Chrome answers with a generic `UnknownError` instead, wrapping a CDP payload:
#
#   unknown error: unhandled inspector error:
#   {"code":-32000,"message":"Node with given id does not belong to the document"}
#
# That matches nothing in `invalid_element_errors`, so it propagates out of
# `synchronize` and errors the test — with a backtrace that names Selenium's
# `element_displayed?` and no test line at all.
#
# The blast radius is wider than it looks. `Capybara::Node::Document#text` and
# `#evaluate_script` are both implemented as `find(:xpath, "/html")` followed by a
# call on the result, so `assert_text` and `page.evaluate_script` run the
# visibility filter over the `<html>` element itself. Anything that swaps the
# document out from under them — a non-Turbo form submit, a Turbo visit, a Turbo
# Stream replacing a subtree — can detach that node between the two round trips.
# That is [run 33249577977](https://github.com/tadasant/zimmer/actions/runs/33249577977),
# where `CostsMobileTest#test_the_calendar_range_is_reachable_and_usable_on_a_phone`
# errored on the page load its own Apply button had started.
#
# So translate the error back into the one Chrome should have raised. This is not
# a retry bolted onto a test: it hands the failure to the retry Capybara already
# has, which re-resolves and asks the document that actually exists. A test that
# genuinely wants a node that is gone still fails — it just fails on its own
# assertion, after the wait, instead of on a CDP error code.
module DetachedNodeErrorTranslation
  DETACHED_NODE = /Node with given id does not belong to the document/

  # Translate, then install. Kept separate from #visible? so it can be tested
  # without a browser: the unit test drives this with a raising block.
  def self.translating
    yield
  rescue ::Selenium::WebDriver::Error::UnknownError => e
    raise unless e.message.match?(DETACHED_NODE)

    raise ::Selenium::WebDriver::Error::StaleElementReferenceError, e.message
  end

  def visible?
    DetachedNodeErrorTranslation.translating { super }
  end

  # Prepended to ChromeNode rather than to Selenium::Node: ChromeNode overrides
  # #visible? and raises from its own body when the driver supports the native
  # `is_element_displayed` command, so a module below it in the chain would only
  # cover the fallback path.
  def self.install!
    Capybara::Selenium::ChromeNode.prepend(self)
  end
end
