# frozen_string_literal: true

require "test_helper"

class ReferencesConfigTest < ActiveSupport::TestCase
  # Test loading references
  test "should load all references from config" do
    refs = ReferencesConfig.all
    assert refs.is_a?(Array)
    assert refs.all? { |r| r.is_a?(ReferencesConfig::Reference) }
  end

  test "should have expected references from config" do
    ids = ReferencesConfig.ids

    assert_includes ids, "engineering-practices"
  end

  # Test finding references
  test "should find reference by id" do
    ref = ReferencesConfig.find("engineering-practices")
    assert_not_nil ref
    assert_equal "engineering-practices", ref.id
    assert_equal "ENGINEERING_PRACTICES.md", ref.file
  end

  test "should return nil for non-existent reference" do
    ref = ReferencesConfig.find("nonexistent")
    assert_nil ref
  end

  test "should raise error with find! for non-existent reference" do
    assert_raises(ReferencesConfig::ReferenceNotFoundError) do
      ReferencesConfig.find!("nonexistent")
    end
  end

  # Test reference existence
  test "should return true for existing reference" do
    assert ReferencesConfig.exists?("engineering-practices")
  end

  test "should return false for non-existent reference" do
    assert_not ReferencesConfig.exists?("nonexistent")
  end

  # Test Reference object attributes
  test "reference should have id title description and file" do
    ref = ReferencesConfig.find("engineering-practices")
    assert_equal "engineering-practices", ref.id
    assert ref.title.is_a?(String)
    assert ref.description.is_a?(String)
    assert_equal "ENGINEERING_PRACTICES.md", ref.file
  end

  test "reference to_h should include all attributes" do
    ref = ReferencesConfig.find("engineering-practices")
    hash = ref.to_h

    assert_equal "engineering-practices", hash[:id]
    assert_equal "ENGINEERING_PRACTICES.md", hash[:file]
    assert hash.key?(:title)
    assert hash.key?(:description)
  end

  # Test reload functionality
  test "should reload configuration" do
    initial_refs = ReferencesConfig.all
    reloaded_refs = ReferencesConfig.reload!
    assert_equal initial_refs.map(&:id), reloaded_refs.map(&:id)
  end

  # Test that reference files actually exist on disk.
  # Local catalog entries carry `file` relative to the references index that
  # declared them. GitHub-catalog entries carry `path` (an absolute path AIR
  # resolved into the provider cache). Validate whichever the entry has.
  #
  # The index directories come from air.json's own `references` list rather than
  # a guessed sibling of air.json: this used to look in
  # `File.expand_path("../references", air_json_dir)`, which resolves one level
  # ABOVE the catalog root, so the directory was never found and the whole test
  # skipped itself in CI.
  test "all references should point to existing files" do
    assert index_dirs.any?, "air.json declares no local references index"

    ReferencesConfig.all.each do |ref|
      assert ref.file.present? || ref.path.present?,
        "Reference '#{ref.id}' has neither file nor path"

      if ref.path.present?
        assert File.exist?(ref.path),
          "Reference '#{ref.id}' points to missing file: #{ref.path}"
      else
        candidates = index_dirs.map { |dir| File.join(dir, ref.file) }
        assert candidates.any? { |p| File.exist?(p) },
          "Reference '#{ref.id}' points to missing file; tried: #{candidates.join(', ')}"
      end
    end
  end

  private

  # Directories holding the local references indexes air.json declares, which is
  # what a local entry's `file` is relative to.
  def index_dirs
    air_json = AirCatalogService.air_json_path
    Array(JSON.parse(File.read(air_json))["references"])
      .reject { |entry| entry.to_s.include?("://") }
      .map { |entry| File.dirname(File.expand_path(entry.to_s, AirCatalogService.air_json_dir)) }
      .uniq
  end
end
