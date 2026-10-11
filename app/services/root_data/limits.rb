# frozen_string_literal: true

module RootData
  # The bounds on an agent root's data store. Hard-coded rather than catalog
  # configurable on purpose: they protect the one shared Postgres, so a root
  # cannot raise them for itself by editing its own catalog entry.
  module Limits
    # Serialized JSON size of one record's `data`.
    MAX_DATA_BYTES = 32.kilobytes

    # Rows one (namespace, collection) may hold. Counted by AgentRootRecordCounter,
    # never by COUNT(*).
    MAX_RECORDS_PER_COLLECTION = 10_000

    # Distinct collections one namespace may have written to.
    MAX_COLLECTIONS_PER_NAMESPACE = 25

    # Writes (put, append, delete) per collection per one-minute window.
    MAX_WRITES_PER_MINUTE = 60
    RATE_WINDOW = 1.minute

    MAX_KEY_LENGTH = 200

    # A declared `retention_days` above this is clamped to it.
    MAX_RETENTION_DAYS = 3650

    DEFAULT_SEARCH_LIMIT = 20
    MAX_SEARCH_LIMIT = 100

    # How much record data one search returns before it stops and says so. A
    # full page of maximum-size records would be ~3 MB of tool result.
    SEARCH_RESPONSE_BUDGET_BYTES = 200.kilobytes
  end
end
