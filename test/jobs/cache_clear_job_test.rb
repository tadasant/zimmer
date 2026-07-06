# frozen_string_literal: true

require "test_helper"

class CacheClearJobTest < ActiveJob::TestCase
  test "job can be enqueued" do
    assert_enqueued_with(job: CacheClearJob) do
      CacheClearJob.perform_later
    end
  end

  test "job can be enqueued with reinstall option" do
    assert_enqueued_with(job: CacheClearJob, args: [ { reinstall: true } ]) do
      CacheClearJob.perform_later(reinstall: true)
    end
  end

  test "job calls CacheClearService.clear_all" do
    mock_results = {
      npm_npx: { cleared: true, path: "/home/rails/.npm/_npx" },
      npm_cache: { cleared: false, message: "Directory does not exist" },
      pip: { cleared: false, message: "Directory does not exist" },
      clone_npm_caches: { cleared: false, message: "No per-clone .npm-cache directories found" }
    }

    CacheClearService.stub(:clear_all, mock_results) do
      assert_nothing_raised do
        CacheClearJob.new.perform
      end
    end
  end

  test "job enqueues McpPackageReinstallJob when reinstall is true and npm cache was cleared" do
    mock_results = {
      npm_npx: { cleared: true, path: "/home/rails/.npm/_npx" },
      npm_cache: { cleared: false, message: "Directory does not exist" },
      pip: { cleared: false, message: "Directory does not exist" },
      clone_npm_caches: { cleared: false, message: "No per-clone .npm-cache directories found" }
    }

    CacheClearService.stub(:clear_all, mock_results) do
      assert_enqueued_with(job: McpPackageReinstallJob) do
        CacheClearJob.new.perform(reinstall: true)
      end
    end
  end

  test "job does not enqueue McpPackageReinstallJob when reinstall is false" do
    mock_results = {
      npm_npx: { cleared: true, path: "/home/rails/.npm/_npx" },
      npm_cache: { cleared: false, message: "Directory does not exist" },
      pip: { cleared: false, message: "Directory does not exist" },
      clone_npm_caches: { cleared: false, message: "No per-clone .npm-cache directories found" }
    }

    CacheClearService.stub(:clear_all, mock_results) do
      assert_no_enqueued_jobs(only: McpPackageReinstallJob) do
        CacheClearJob.new.perform(reinstall: false)
      end
    end
  end

  test "job does not enqueue McpPackageReinstallJob when no npm cache was cleared" do
    mock_results = {
      npm_npx: { cleared: false, message: "Directory does not exist" },
      npm_cache: { cleared: false, message: "Directory does not exist" },
      pip: { cleared: true, path: "/home/rails/.cache/pip" },
      clone_npm_caches: { cleared: false, message: "No per-clone .npm-cache directories found" }
    }

    CacheClearService.stub(:clear_all, mock_results) do
      assert_no_enqueued_jobs(only: McpPackageReinstallJob) do
        CacheClearJob.new.perform(reinstall: true)
      end
    end
  end

  test "job handles errors in cache clearing gracefully" do
    mock_results = {
      npm_npx: { cleared: false, error: "Permission denied" },
      npm_cache: { cleared: false, error: "Permission denied" },
      pip: { cleared: false, error: "Permission denied" },
      clone_npm_caches: { cleared: false, message: "Clones directory does not exist" }
    }

    CacheClearService.stub(:clear_all, mock_results) do
      assert_nothing_raised do
        CacheClearJob.new.perform
      end
    end
  end
end
