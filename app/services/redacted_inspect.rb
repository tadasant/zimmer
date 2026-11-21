# frozen_string_literal: true

# A safe `inspect` for objects that hold secret values.
#
# Ruby's default `inspect` walks every instance variable, and Struct, Data and
# Hash print every member. So `p`, `pp`, `inspect`, an exception message or a
# log line naming one of these objects prints whatever it holds. For
# SecretProviders::Env that is the whole process environment, and every value
# in it. A string like that ends up in a transcript or a log, and a secret
# that has been printed has to be rotated.
#
# Including this module replaces `inspect`, `to_s` and `pretty_print` with
# `#<ClassName field=value ...>`, where the fields are only the ones the class
# names in `redacted_inspect_fields`. A class lists fields that are safe to
# show: names, paths, counts, never values. With no override nothing but the
# class name is printed.
#
# Reading values is unchanged: `get`, `[]`, `to_h`, member readers. Only how
# the object describes itself changes.
module RedactedInspect
  # @return [Hash{Symbol => Object}] fields that are safe to print. Override in
  #   the including class.
  def redacted_inspect_fields = {}

  def inspect
    fields = redacted_inspect_fields.map { |key, value| "#{key}=#{value.inspect}" }
    [ "#<#{self.class.name || 'anonymous'}", *fields, "(values redacted)>" ].join(" ")
  end

  def to_s = inspect

  def pretty_print(printer) = printer.text(inspect)
end
