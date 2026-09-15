# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
load File.expand_path("../bin/dworkenv", __dir__)

class DiscourseProjectTest < Minitest::Test
  def setup
    @temporary = Dir.mktmpdir("dworkenv-test-")
    @environment = ENV.to_h
    ENV["DWORKENV_CACHE_HOME"] = File.join(@temporary, "cache")
    ENV.delete("DWORKENV_DISCOURSE_REF")
    ENV.delete("DWORKENV_DISCOURSE_REPOSITORY")
  end

  def teardown
    ENV.replace(@environment)
    FileUtils.remove_entry(@temporary)
  end

  def test_core_checkouts_keep_their_original_identity_and_lock_location
    core = core_repository
    project = in_directory(core) { DiscourseProject.new }

    refute project.plugin?
    assert_equal File.realpath(core), project.root
    assert_equal project.root, project.discourse_root
    assert_equal File.join(project.root, "tmp/workenv"), project.state_directory
    assert_equal ["spec"], project.spec_arguments([])
  end

  def test_plugin_worktrees_use_metadata_name_and_separate_managed_checkouts
    plugin = repository("plugin")
    File.write(File.join(plugin, "plugin.rb"), "# name: discourse-example\n")
    commit(plugin)
    first = File.join(@temporary, "sleepy-fox")
    second = File.join(@temporary, "quiet-owl")
    git("-C", plugin, "worktree", "add", "--detach", first)
    git("-C", plugin, "worktree", "add", "--detach", second)
    FileUtils.mkdir_p(File.join(first, "spec/models"))

    first_project = in_directory(File.join(first, "spec/models")) { DiscourseProject.new }
    second_project = in_directory(second) { DiscourseProject.new }

    assert first_project.plugin?
    assert_equal "discourse-example", first_project.plugin_name
    assert_equal File.realpath(first), first_project.root
    refute_equal first_project.discourse_root, second_project.discourse_root
    refute File.exist?(first_project.discourse_root)
    refute File.exist?(File.join(first, "tmp"))
  end

  def test_plugin_spec_paths_and_line_numbers_are_mapped_without_losing_options
    plugin = plugin_repository
    project = in_directory(plugin) { DiscourseProject.new }

    assert_equal ["plugins/discourse-example/spec"], project.spec_arguments([])
    assert_equal ["plugins/discourse-example/spec", "--format", "progress"], project.spec_arguments(%w[-- --format progress])
    assert_equal ["plugins/discourse-example/spec/models/example_spec.rb:12", "--format", "documentation"],
                 project.spec_arguments(%w[spec/models/example_spec.rb:12 -- --format documentation])
    assert_equal ["plugins/discourse-example/spec/model_spec.rb:8"],
                 project.spec_arguments(["#{project.root}/spec/model_spec.rb:8"])
  end

  def test_managed_checkout_is_downloaded_once_and_stays_pinned
    core = core_repository
    plugin = plugin_repository
    ENV["DWORKENV_DISCOURSE_REPOSITORY"] = core
    project = in_directory(plugin) { DiscourseProject.new }
    FileUtils.mkdir_p(project.state_directory)
    first_revision = git("-C", core, "rev-parse", "HEAD").strip

    project.ensure_checkout
    File.write(File.join(core, "new-file"), "new revision")
    commit(core)
    project.ensure_checkout

    assert_equal first_revision, git("-C", project.discourse_root, "rev-parse", "HEAD").strip
    refute File.exist?(File.join(project.discourse_root, "new-file"))
    assert_empty git("-C", plugin, "status", "--porcelain").strip
  end

  def test_system_specs_are_detected_for_default_directory_and_selected_file_runs
    plugin = plugin_repository
    FileUtils.mkdir_p(File.join(plugin, "spec/system"))
    FileUtils.mkdir_p(File.join(plugin, "spec/models"))
    File.write(File.join(plugin, "spec/system/example_spec.rb"), "")
    File.write(File.join(plugin, "spec/models/example_spec.rb"), "")
    project = in_directory(plugin) { DiscourseProject.new }

    assert project.system_specs?([])
    assert project.system_specs?(%w[-- --format progress])
    assert project.system_specs?(["spec/system/example_spec.rb:12"])
    refute project.system_specs?(["spec/models"])
    refute project.system_specs?(["spec/models/example_spec.rb"])
  end

  def test_failed_download_can_be_retried_without_removing_a_partial_checkout
    plugin = plugin_repository
    project = in_directory(plugin) { DiscourseProject.new }
    FileUtils.mkdir_p(project.state_directory)
    ENV["DWORKENV_DISCOURSE_REPOSITORY"] = File.join(@temporary, "missing")

    assert_raises(RuntimeError) { project.ensure_checkout }
    refute File.exist?(project.discourse_root)
    refute File.exist?(File.join(project.state_directory, "discourse-cloning"))

    ENV["DWORKENV_DISCOURSE_REPOSITORY"] = core_repository
    project.ensure_checkout
    assert File.file?(File.join(project.discourse_root, ".devcontainer/devcontainer.json"))
  end

  def test_invalid_target_or_plugin_name_fails_before_allocating_an_environment
    root = repository("invalid")
    assert_raises(RuntimeError) { in_directory(root) { DiscourseProject.new } }
    File.write(File.join(root, "plugin.rb"), "# name: ../../bad\n")
    assert_raises(RuntimeError) { in_directory(root) { DiscourseProject.new } }
    refute File.exist?(ENV.fetch("DWORKENV_CACHE_HOME"))
  end

  def test_container_names_follow_branches_prs_and_detached_worktree_directories
    core = core_repository
    git("-C", core, "checkout", "-b", "feature/new-login")
    assert_equal "discourse-feature-new-login", in_directory(core) { DiscourseProject.new.container_name }
    git("-C", core, "checkout", "-b", "pr-1234")
    assert_equal "discourse-PR-1234", in_directory(core) { DiscourseProject.new.container_name }
    plugin = plugin_repository
    git("-C", plugin, "checkout", "-b", "pull/123")
    assert_equal "discourse-example-PR-123", in_directory(plugin) { DiscourseProject.new.container_name }
    detached = File.join(@temporary, "discourse-login-pr215")
    git("-C", plugin, "worktree", "add", "--detach", detached)
    assert_equal "discourse-example-PR-215", in_directory(detached) { DiscourseProject.new.container_name }
  end

  def test_image_reuse_refresh_and_missing_image
    environment = WorktreeEnvironment.allocate
    pulls = []
    info = { "Id" => "sha256:example", "Created" => (Time.now - 49 * 3600).iso8601 }
    status = Struct.new(:success?).new(true)
    environment.define_singleton_method(:docker) { |*args| pulls << args }
    environment.define_singleton_method(:capture) { |*args| JSON.generate([info]) }
    original_capture = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3) { |*args| [JSON.generate([info]), "", status] }
    begin
      environment.send(:ensure_image, "example:old")
      environment.send(:ensure_image, "example:old")
      assert_equal [["pull", "example:old"]], pulls
      marker = Dir.glob(File.join(ENV.fetch("DWORKENV_CACHE_HOME"), "images/*.json")).first
      File.write(marker, JSON.generate(id: info["Id"], checked_at: Time.now.to_f - 49 * 3600))
      environment.send(:ensure_image, "example:old")
      assert_equal 2, pulls.length
      info["Created"] = (Time.now - 3600).iso8601
      environment.send(:ensure_image, "example:recent")
      assert_equal 2, pulls.length
      status = Struct.new(:success?).new(false)
      environment.send(:ensure_image, "example:missing")
      assert_equal ["pull", "example:missing"], pulls.last
    ensure
      Open3.define_singleton_method(:capture3, original_capture)
    end
  end

  private

  def repository(name)
    path = File.join(@temporary, name)
    git("init", "--quiet", "-b", "main", path)
    path
  end

  def plugin_repository
    path = repository("plugin")
    File.write(File.join(path, "plugin.rb"), "# name: discourse-example\n")
    commit(path)
    path
  end

  def core_repository
    path = repository("core")
    FileUtils.mkdir_p(File.join(path, ".devcontainer"))
    FileUtils.mkdir_p(File.join(path, "bin"))
    File.write(File.join(path, ".devcontainer/devcontainer.json"), '{"image":"example"}')
    File.write(File.join(path, "bin/rspec"), "#!/usr/bin/env ruby\n")
    commit(path)
    path
  end

  def commit(path)
    git("-C", path, "add", ".")
    git("-C", path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Fixture")
  end

  def git(*arguments)
    output, error, status = Open3.capture3("git", *arguments)
    raise error unless status.success?
    output
  end

  def in_directory(path, &block)
    Dir.chdir(path, &block)
  end
end
