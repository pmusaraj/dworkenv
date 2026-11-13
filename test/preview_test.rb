# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
load File.expand_path("../bin/dworkenv", __dir__)

class PreviewTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("dworkenv-preview-test-")
    @environment = ENV.to_h
    ENV["DWORKENV_TAILSCALE_AUTH_KEY_FILE"] = File.join(@root, "auth-key")
  end

  def teardown
    ENV.replace(@environment)
    FileUtils.remove_entry(@root)
  end

  def test_content_edits_additions_and_deletions_invalidate_assets
    source = write("frontend/example.js", "one")
    initial = snapshot
    mtime = File.mtime(source)
    File.write(source, "two")
    File.utime(mtime, mtime, source)
    refute_equal initial["source"], snapshot["source"]
    File.write(source, "one")
    assert_equal initial["source"], snapshot["source"]
    added = write("frontend/new.js", "new")
    refute_equal initial["source"], snapshot["source"]
    File.unlink(added)
    assert_equal initial["source"], snapshot["source"]
    File.unlink(source)
    refute_equal initial["source"], snapshot["source"]
  end

  def test_missing_outputs_and_manifest_changes_invalidate_cache
    bundle = write("frontend/discourse/dist/app.js", "compiled")
    manifest = { entrypoints: { discourse: "app.js" }, chunks: { "app.js" => {} } }
    write("frontend/discourse/dist/manifest/manifest.json", JSON.generate(manifest))
    original = snapshot
    assert Dworkenv::PreviewAssets.reusable?(original, original)
    write("frontend/discourse/dist/manifest/build.json", '{"status":"ok"}')
    write("frontend/node_modules/generated.js", "ignored")
    write("app/assets/generated/example/js/plugins/example.js", "compiled plugin")
    assert_equal original, snapshot
    File.unlink(bundle)
    refute Dworkenv::PreviewAssets.reusable?(snapshot, original)
    assert_equal original["source"], snapshot["source"]
    write("frontend/discourse/dist/app.js", "compiled")
    manifest[:other] = true
    write("frontend/discourse/dist/manifest/manifest.json", JSON.generate(manifest))
    refute Dworkenv::PreviewAssets.reusable?(snapshot, original)
  end

  def test_source_files_named_generated_are_still_hashed
    source = write("app/assets/javascripts/generated/example.js", "one")
    original = snapshot
    File.write(source, "two")
    refute_equal original["source"], snapshot["source"]
  end

  def test_linked_sources_are_hashed_and_cycles_are_skipped
    external = write("external/plugin.rb", "one")
    FileUtils.mkdir_p(File.join(@root, "plugins"))
    File.symlink(File.dirname(external), File.join(@root, "plugins/example"))
    File.symlink(File.dirname(external), File.join(@root, "external/cycle"))
    original = snapshot
    File.write(external, "two")
    refute_equal original["source"], snapshot["source"]
  end

  def test_public_origins_are_validated_before_shell_generation
    endpoint = Dworkenv::PublicEndpoint.new("https://preview.example.test:8443/")
    assert_equal "preview.example.test", endpoint.hostname
    assert_equal 8443, endpoint.uri.port
    assert endpoint.https?
    assert_equal "https://preview.example.test:8443", endpoint.to_s
    %w[ftp://example.test https://user:pass@example.test https://example.test/path https://example.test?q=1 https://example.test#fragment].each do |value|
      assert_raises(ArgumentError) { Dworkenv::PublicEndpoint.new(value) }
    end
    assert_raises(ArgumentError) { Dworkenv::PublicEndpoint.new("https://example.test;touch") }
  end

  def test_settings_are_saved_and_invalid_options_do_not_replace_them
    project = Struct.new(:state_directory).new(@root)
    instance = WorktreeEnvironment.allocate
    instance.instance_variable_set(:@project, project)
    instance.instance_variable_set(:@settings, {})
    instance.send(:configure_start, %w[--preview --public-url https://preview.example.test])
    saved = JSON.parse(File.read(File.join(@root, "preview.json")))
    assert saved["preview"]
    assert_equal "https://preview.example.test", saved["public_url"]
    assert_raises(ArgumentError) { instance.send(:configure_start, %w[--public-url https://example.test/path]) }
    assert_equal saved, JSON.parse(File.read(File.join(@root, "preview.json")))
    instance.send(:configure_start, %w[--live --local])
    saved = JSON.parse(File.read(File.join(@root, "preview.json")))
    refute saved["preview"]
    refute saved.key?("public_url")
  end

  def test_external_plugin_mounts_preserve_symlink_targets
    external = write("external/plugin.rb", "# name: example")
    source = File.join(@root, "core")
    FileUtils.mkdir_p(File.join(source, "plugins"))
    File.symlink(File.dirname(external), File.join(source, "plugins/example"))
    instance = WorktreeEnvironment.allocate
    instance.instance_variable_set(:@source, source)
    assert_equal [[File.realpath(File.dirname(external)), File.dirname(external)]], instance.send(:linked_plugins)
    File.unlink(external)
    FileUtils.remove_entry(File.dirname(external))
    assert_raises(RuntimeError) { instance.send(:linked_plugins) }
  end

  def test_auth_key_permissions_and_absent_key
    assert_nil Dworkenv::Tailscale.read_key
    File.write(ENV.fetch("DWORKENV_TAILSCALE_AUTH_KEY_FILE"), "tskey-auth-test-fixture\n", perm: 0o600)
    assert_equal "tskey-auth-test-fixture", Dworkenv::Tailscale.read_key
    File.chmod(0o644, ENV.fetch("DWORKENV_TAILSCALE_AUTH_KEY_FILE"))
    assert_raises(RuntimeError) { Dworkenv::Tailscale.read_key }
  end

  def test_hidden_prompt_saves_a_private_key_without_printing_it
    input = Object.new
    input.define_singleton_method(:tty?) { true }
    input.define_singleton_method(:noecho) { |&block| block.call(self) }
    input.define_singleton_method(:gets) { "tskey-auth-test-fixture\n" }
    old_input = $stdin
    begin
      $stdin = input
      output, error = capture_io { Dworkenv::Tailscale.store_key }
      refute_includes output + error, "tskey-auth-test-fixture"
      assert_equal 0o600, File.stat(ENV.fetch("DWORKENV_TAILSCALE_AUTH_KEY_FILE")).mode & 0o777
      assert_equal "tskey-auth-test-fixture", Dworkenv::Tailscale.read_key
    ensure
      $stdin = old_input
    end
  end

  def test_authentication_uses_stdin_and_redacts_failures
    key = "tskey-auth-test-fixture"
    commands = []
    original = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3) do |*args, **options|
      commands << [args, options]
      ["", "rejected #{key}", Struct.new(:success?).new(false)]
    end
    begin
      companion = Dworkenv::Tailscale.new(@root, "test-volumes")
      error = assert_raises(RuntimeError) { companion.send(:authenticate, "preview", key) }
      refute_includes error.message, key
      refute_includes commands.first.first.join(" "), key
      assert_equal key + "\n", commands.first.last[:stdin_data]
    ensure
      Open3.define_singleton_method(:capture3, original)
    end
  end

  def test_pending_authentication_is_not_restarted
    companion, commands = fake_companion("NeedsLogin", "https://login.example.test/authorize")
    error = assert_raises(RuntimeError) { companion.start(application, "volume-label") }
    assert_includes error.message, "https://login.example.test/authorize"
    assert_empty commands
  end

  def test_running_identity_does_not_read_a_key_and_keeps_its_hostname
    File.write(ENV.fetch("DWORKENV_TAILSCALE_AUTH_KEY_FILE"), "invalid")
    companion, commands = fake_companion("Running")
    assert_equal "https://preview.example.ts.net", companion.start(application, "volume-label")
    assert_equal "restart", commands.first[1]
    assert commands.last.include?("--https=443")
    refute commands.any? { |command| command.include?("up") }
  end

  def test_replacing_application_reuses_companion_state_volume
    companion, commands = fake_companion("Running")
    companion.start(application.merge("Id" => "replacement-id"), "volume-label")
    assert commands.any? { |args| args[1..2] == ["rm", "--force"] }
    creation = commands.find { |args| args[1] == "run" }
    assert_includes creation, "container:replacement-id"
    assert creation.any? { |arg| arg == "type=volume,source=test-volumes-tailscale,target=/var/lib/tailscale" }
    refute commands.any? { |args| args[1..2] == ["volume", "rm"] }
  end

  def test_stop_and_destroy_touch_only_the_owned_companion
    companion, commands = fake_companion("Running")
    companion.stop
    companion.destroy
    assert_equal ["stop", "rm"], commands.map { |args| args[1] }
    assert commands.all? { |args| args.last.start_with?("dworkenv-tailscale-") }
  end

  private

  def fake_companion(state, auth_url = "")
    companion = Dworkenv::Tailscale.new(@root, "test-volumes")
    commands = []
    companion.define_singleton_method(:info) { { "HostConfig" => { "NetworkMode" => "container:app-id" }, "State" => { "Running" => true } } }
    companion.define_singleton_method(:status) { { "BackendState" => state, "AuthURL" => auth_url, "Self" => { "DNSName" => "preview.example.ts.net." } } }
    companion.define_singleton_method(:command) { |*args, **_options| commands << args }
    [companion, commands]
  end

  def application
    { "Id" => "app-id", "Name" => "/example-preview" }
  end

  def write(relative, content)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def snapshot
    Dworkenv::PreviewAssets.snapshot(@root)
  end
end
