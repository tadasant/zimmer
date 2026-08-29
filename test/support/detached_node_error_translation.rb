# frozen_string_literal: true

require "selenium-webdriver"
require "capybara"
require "capybara/selenium/nodes/chrome_node"

# Chrome misreports a node that left the document, and Capybara cannot retry an
# error it does not recognize.
#
# Why this exists
# ---------------
# Capybara resolves a set of candidate elements and then calls back on each
# handle — is it displayed, what is its text — as separate round trips. If the
# document is replaced in between, the handle belongs to a document that no
# longer exists. WebDriver's answer for that is `StaleElementReferenceError`,
# which Capybara lists in `invalid_element_errors`; its `synchronize` loop
# swallows those and retries by re-resolving against the page that exists now.
# That retry is the whole reason a Capybara suite tolerates a re-rendering page.
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
# The blast radius is wider than "a test that holds an element across a
# re-render". `Capybara::Node::Document#text` is `find(:xpath, "/html")` followed
# by `#text` on the result, so **`assert_text` runs the visibility filter and
# then a text read against the `<html>` element itself** — two exposed calls on a
# handle no test ever named. Anything that swaps the document out from under them
# can detach it: a non-Turbo form submit, a Turbo visit, a Turbo Stream replacing
# a subtree. That is
# [run 33249577977](https://github.com/tadasant/zimmer/actions/runs/33249577977),
# where `CostsMobileTest#test_the_calendar_range_is_reachable_and_usable_on_a_phone`
# errored on the page load its own Apply button had started.
#
# Translating the error back into the one Chrome should have raised hands the
# failure to the retry Capybara already has, which re-resolves and asks the
# document that actually exists. A test that genuinely wants a node that is gone
# still fails, on its own assertion, once the wait expires.
module DetachedNodeErrorTranslation
  DETACHED_NODE = /Node with given id does not belong to the document/

  # The read paths Capybara calls on an already-resolved handle while resolving a
  # query or reading text. `#[]` and `#value` are absent because
  # `Capybara::Selenium::Node` already rescues `WebDriverError` around them, which
  # `UnknownError` is a subclass of.
  def visible?    = DetachedNodeErrorTranslation.translating { super }
  def visible_text = DetachedNodeErrorTranslation.translating { super }
  def all_text    = DetachedNodeErrorTranslation.translating { super }

  # Kept separate from the wrappers so it can be tested without a browser: the
  # unit test drives it with a raising block.
  def self.translating
    yield
  rescue ::Selenium::WebDriver::Error::UnknownError => e
    raise unless e.message.match?(DETACHED_NODE)

    raise ::Selenium::WebDriver::Error::StaleElementReferenceError, e.message
  end

  # Prepended to ChromeNode rather than to Selenium::Node: ChromeNode overrides
  # #visible? and raises from its own body when the driver supports the native
  # `is_element_displayed` command, so a module below it in the chain would only
  # cover the fallback path. #visible_text and #all_text are inherited, and a
  # prepend sits ahead of the whole chain either way.
  def self.install!
    Capybara::Selenium::ChromeNode.prepend(self)
  end
end
