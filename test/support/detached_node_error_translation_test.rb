# frozen_string_literal: true

require "test_helper"
require "selenium-webdriver"
require_relative "detached_node_error_translation"

# Pins the one thing the browser suite cannot demonstrate on demand: that Chrome's
# misreported detached-node error is handed back to Capybara as the retryable error
# it actually is.
#
# The race itself is not reproducible to order — it needs a document swap to land
# inside the two round trips of a visibility check — so it is asserted here, on the
# translation, rather than by running the flaky test until it loses again.
class DetachedNodeErrorTranslationTest < ActiveSupport::TestCase
  # Verbatim from the CI failure that prompted this:
  # https://github.com/tadasant/zimmer/actions/runs/33249577977
  CDP_MESSAGE = "unknown error: unhandled inspector error: " \
                '{"code":-32000,"message":"Node with given id does not belong to the document"}'

  test "Chrome's detached-node UnknownError becomes the stale reference Capybara retries" do
    error = assert_raises(Selenium::WebDriver::Error::StaleElementReferenceError) do
      DetachedNodeErrorTranslation.translating do
        raise Selenium::WebDriver::Error::UnknownError, CDP_MESSAGE
      end
    end

    # Selenium appends its own documentation link to the message it builds, so this
    # is a containment check: what matters is that the original CDP text survives,
    # or the next person to hit this has nothing to grep for.
    assert_includes error.message, CDP_MESSAGE
  end

  test "the translated error is one Capybara's synchronize loop swallows" do
    driver = Capybara::Selenium::Driver.allocate

    assert_includes driver.invalid_element_errors, Selenium::WebDriver::Error::StaleElementReferenceError,
      "translating into an error Capybara does not retry would fix nothing"
  end

  test "any other UnknownError is left alone" do
    error = assert_raises(Selenium::WebDriver::Error::UnknownError) do
      DetachedNodeErrorTranslation.translating do
        raise Selenium::WebDriver::Error::UnknownError, "unknown error: cannot determine loading status"
      end
    end

    assert_equal "unknown error: cannot determine loading status", error.message
  end

  test "a non-UnknownError passes through untouched" do
    assert_raises(Capybara::ElementNotFound) do
      DetachedNodeErrorTranslation.translating { raise Capybara::ElementNotFound, "no such element" }
    end
  end

  test "a block that does not raise returns its value" do
    assert_equal :visible, DetachedNodeErrorTranslation.translating { :visible }
  end

  test "install! lands ahead of Capybara's own visible? on the node class Chrome uses" do
    DetachedNodeErrorTranslation.install!

    ancestors = Capybara::Selenium::ChromeNode.ancestors
    assert_includes ancestors, DetachedNodeErrorTranslation
    assert_operator ancestors.index(DetachedNodeErrorTranslation), :<,
      ancestors.index(Capybara::Selenium::ChromeNode),
      "prepended, not included — ChromeNode defines its own #visible? and would win otherwise"
  end
end
