# frozen_string_literal: true

# The lock discipline every discretionary write on /issues follows.
#
# THE GUARD HAS TO BE INSIDE THE LOCK, and it is easy to get wrong: reading an
# item, checking it is `queued`, and only then taking WorkBacklog::Ranking's
# advisory lock leaves a window the groomer's pull fits straight through. The
# pull holds the lock, starts the very item the reader clicked, and releases —
# and the click, whose guard passed against a snapshot taken before any of that,
# now writes over a row with a live session against it. A remove is the bad one:
# the item goes to `removed` while its session keeps running, so it leaves
# `in_flight`, the WIP ceiling undercounts, and the fleet over-spawns against a
# number that is quietly wrong.
#
# So the check is a re-read under the lock, with a row lock — exactly what
# WorkBacklog::Start does (`WorkBacklogItem.lock.find` then `queued?`) and what
# WorkBacklog::Pull does (`WorkBacklogItem.queued.lock.find_by`). Serialising the
# WRITE is not enough on its own; the read the decision rests on has to be inside
# the same lock.
#
# By row id, never by key: these controls are rendered from rows the page already
# loaded, so the id is what they have — and a key resolves to "the queued row for
# that key, else the most recent one", which is a second way to land on the wrong
# row for controls whose whole risk is landing on the wrong row.
module WorkBacklogQueuedWrite
  extend ActiveSupport::Concern

  private

  # Yields the item — re-read under the lock and still `queued` — to a block that
  # performs the write and returns the notice to show. A row that was started,
  # removed or deleted between the page render and the click is reported instead,
  # and nothing is written.
  #
  # `verb` is the past participle the refusal reads with: "pinned", "unpinned",
  # "removed".
  def write_to_queued_item(verb)
    notice, alert = WorkBacklog::Ranking.with_lock do
      item = WorkBacklogItem.lock.find_by(id: params[:id].to_s)

      if item.nil?
        [ nil, "That backlog item no longer exists." ]
      elsif !item.queued?
        [ nil, "#{item.key} is #{item.status}, so it cannot be #{verb}." ]
      else
        [ yield(item), nil ]
      end
    end

    back_to_issues(notice: notice, alert: alert)
  end
end
