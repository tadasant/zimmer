require "test_helper"

class CategoryTest < ActiveSupport::TestCase
  def setup
    Category.delete_all
  end

  test "is valid with a name" do
    category = Category.new(name: "ingestion pipeline")
    assert category.valid?
  end

  test "requires a name" do
    category = Category.new(name: "")
    assert_not category.valid?
    assert_includes category.errors[:name], "can't be blank"
  end

  test "rejects a name longer than 100 characters" do
    category = Category.new(name: "x" * 101)
    assert_not category.valid?
  end

  test "enforces case-insensitive uniqueness on name" do
    Category.create!(name: "Backlog")
    dup = Category.new(name: "backlog")
    assert_not dup.valid?
    assert_includes dup.errors[:name], "has already been taken"
  end

  test "assigns an incrementing default position on create" do
    first = Category.create!(name: "first")
    second = Category.create!(name: "second")

    assert_equal 0, first.position
    assert_equal 1, second.position
  end

  test "respects an explicitly provided position" do
    category = Category.create!(name: "explicit", position: 42)
    assert_equal 42, category.position
  end

  test "ordered scope sorts by position ascending" do
    c2 = Category.create!(name: "b", position: 2)
    c0 = Category.create!(name: "a", position: 0)
    c1 = Category.create!(name: "c", position: 1)

    assert_equal [ c0, c1, c2 ], Category.ordered.to_a
  end

  test "is valid without a description" do
    category = Category.new(name: "no desc")
    assert category.valid?
  end

  test "accepts a description" do
    category = Category.create!(name: "with desc", description: "Sessions about the ingestion pipeline")
    assert_equal "Sessions about the ingestion pipeline", category.reload.description
  end

  test "accepts a description of exactly 1000 characters" do
    category = Category.new(name: "at limit", description: "x" * 1000)
    assert category.valid?
  end

  test "rejects a description longer than 1000 characters" do
    category = Category.new(name: "too long", description: "x" * 1001)
    assert_not category.valid?
    assert_includes category.errors[:description], "is too long (maximum is 1000 characters)"
  end

  test "nullifies sessions category_id when destroyed" do
    category = Category.create!(name: "doomed")
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", category: category)

    category.destroy

    assert_nil session.reload.category_id
  end

  test "strips surrounding whitespace from the name" do
    category = Category.create!(name: "  trimmed  ")
    assert_equal "trimmed", category.name
  end

  test "stores a blank description as null" do
    category = Category.create!(name: "spacey", description: "   ")
    assert_nil category.reload.description
  end

  test "reorder! rewrites each category position to its index in the id list" do
    a = Category.create!(name: "A", position: 0)
    b = Category.create!(name: "B", position: 1)
    c = Category.create!(name: "C", position: 2)

    Category.reorder!([ c.id, a.id, b.id ])

    assert_equal 0, c.reload.position
    assert_equal 1, a.reload.position
    assert_equal 2, b.reload.position
    assert_equal [ c, a, b ], Category.ordered.to_a
  end

  test "reorder! drops zero and non-integer ids and ignores unknown ids" do
    a = Category.create!(name: "A", position: 0)
    b = Category.create!(name: "B", position: 1)

    Category.reorder!([ b.id, 0, 999_999, a.id ])

    # Zero ids are dropped before indexing; the surviving order is [b, 999999, a],
    # so b -> 0 and a -> 2 (the unknown id at index 1 touches no rows).
    assert_equal 0, b.reload.position
    assert_equal 2, a.reload.position
  end

  test "reorder! leaves categories omitted from the list at their existing position" do
    a = Category.create!(name: "A", position: 0)
    c = Category.create!(name: "C", position: 9)

    Category.reorder!([ a.id ])

    assert_equal 0, a.reload.position
    assert_equal 9, c.reload.position
  end

  test "reorder! positions the uncategorized sentinel via AppSetting#uncategorized_position" do
    a = Category.create!(name: "A", position: 0)
    b = Category.create!(name: "B", position: 1)

    Category.reorder!([ a.id, Category::UNCATEGORIZED_SENTINEL, b.id ])

    # Real categories are indexed normally; the sentinel's index is persisted on
    # the app setting rather than a Category row.
    assert_equal 0, a.reload.position
    assert_equal 2, b.reload.position
    assert_equal 1, AppSetting.current.uncategorized_position
  end
end
