# frozen_string_literal: true

module BoardCategories
  # Rewrite the order of Your board's categories in one transaction.
  #
  # Takes the order the operator dropped them in, top first, and numbers them
  # 0..n-1. Categories left out of the list keep their relative order and go
  # below the listed ones, so a caller that names a subset (an agent ranking two
  # categories) never scrambles the rest.
  class Reorder
    class Error < StandardError; end

    # @param ids [Array<Integer>] category ids, top first
    # @return [Array<BoardCategory>] every category, in its new order
    def self.call(ids:)
      ids = Array(ids).map { |id| Integer(id, exception: false) }
      raise Error, "category_ids must be a list of category ids." if ids.empty? || ids.any?(&:nil?)
      raise Error, "category_ids contains duplicates." if ids.uniq.size != ids.size

      BoardCategory.transaction do
        all = BoardCategory.lock.ordered.to_a
        by_id = all.index_by(&:id)
        unknown = ids - by_id.keys
        raise Error, "No board category with id #{unknown.join(', ')}." if unknown.any?

        ordered = ids.map { |id| by_id[id] } + all.reject { |c| ids.include?(c.id) }
        ordered.each_with_index do |category, index|
          category.update_columns(position: index, updated_at: Time.current) if category.position != index
        end
        ordered
      end
    end
  end
end
