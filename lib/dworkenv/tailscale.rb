# frozen_string_literal: true

require "digest"
require "fileutils"
require "io/console"
require "json"
require "open3"
require "tempfile"
require_relative "public_endpoint"

module Dworkenv
  class Tailscale
    LABEL = "org.discourse.workenv.tailscale.path"
    IMAGE = "tailscale/tailscale:stable"

    def self.key_path
      ENV["DWORKENV_TAILSCALE_AUTH_KEY_FILE"] ||
        File.join(ENV.fetch("XDG_CONFIG_HOME", File.join(Dir.home, ".config")), "dworkenv/tailscale-auth-key")
    end

    def self.validate_key(key)
      raise "Expected a Tailscale auth key starting with tskey-auth-" unless key.match?(/\Atskey-auth-[A-Za-z0-9-]+\z/)
      key
    end

    def self.store_key
      raise "Run auth-key in an interactive terminal for hidden input" unless $stdin.tty?
      $stderr.print "Reusable Tailscale auth key (hidden): "
      key = validate_key($stdin.noecho(&:gets).to_s.strip)
      $stderr.puts
      directory = File.dirname(key_path)
      FileUtils.mkdir_p(directory, mode: 0o700)
      Tempfile.create("auth-key", directory) do |file|
        file.write(key + "\n")
        file.close
        File.rename(file.path, key_path)
      end
      puts "Saved auth key to #{key_path} (mode 600)"
    end

    def self.read_key
      return unless File.exist?(key_path)
      stat = File.stat(key_path)
      raise "Auth key file must be owned by you with mode 600" unless stat.uid == Process.uid && (stat.mode & 0o077).zero?
      validate_key(File.read(key_path).strip)
    end

    def initialize(root, volume_prefix)
      @root = root
      @name = "dworkenv-tailscale-#{Digest::SHA256.hexdigest(root)[0, 16]}"
      @volume = "#{volume_prefix}-tailscale"
    end

    def info
      output, _error, status = Open3.capture3("docker", "inspect", @name)
      return unless status.success?
      value = JSON.parse(output).first
      raise "Refusing to modify an unrelated Tailscale container" unless value.dig("Config", "Labels", LABEL) == @root
      value
    end

    def stop
      command("docker", "stop", @name) if info&.dig("State", "Running")
    end

    def destroy
      command("docker", "rm", "--force", @name) if info
    end

    def start(application, volume_label)
      existing = info
      network = "container:#{application.fetch("Id")}"
      if existing && existing.dig("HostConfig", "NetworkMode") != network
        destroy
        existing = nil
      end
      if existing
        # Do not invalidate a pending interactive sign-in by restarting its daemon.
        pending = existing.dig("State", "Running") && status["AuthURL"].to_s != ""
        command("docker", "restart", @name) unless pending
      else
        command("docker", "volume", "create", "--label", "#{volume_label}=#{@root}", @volume)
        command(
          "docker", "run", "--detach", "--name", @name, "--network", network,
          "--restart", "unless-stopped", "--label", "#{LABEL}=#{@root}",
          "--mount", "type=volume,source=#{@volume},target=/var/lib/tailscale",
          "--entrypoint", "tailscaled", ENV.fetch("DWORKENV_TAILSCALE_IMAGE", IMAGE),
          "--tun=userspace-networking", "--state=/var/lib/tailscale/tailscaled.state",
        )
      end
      current = {}
      30.times do
        current = status
        break if %w[Running NeedsLogin NeedsMachineAuth Stopped].include?(current["BackendState"])
        sleep 1
      end
      if current["BackendState"] != "Running"
        hostname = application.fetch("Name").delete_prefix("/").downcase[0, 50].sub(/-+\z/, "")
        if key = self.class.read_key
          authenticate(hostname, key)
        elsif current["AuthURL"].to_s.empty?
          command("docker", "exec", @name, "tailscale", "up", "--hostname=#{hostname}", "--accept-dns=false", "--timeout=5s", check: false)
        end
        current = status
        unless current["BackendState"] == "Running"
          raise "Tailscale authorization required: #{current["AuthURL"].to_s.empty? ? "check the device in your tailnet admin console" : current["AuthURL"]}. Then rerun dworkenv up."
        end
      end
      hostname = current.fetch("Self").fetch("DNSName").delete_suffix(".")
      endpoint = PublicEndpoint.new("https://#{hostname}")
      raise "Unexpected Tailscale DNS name" unless hostname.end_with?(".ts.net")
      command("docker", "exec", @name, "tailscale", "serve", "--bg", "--https=443", "http://127.0.0.1:3000")
      endpoint.to_s
    end

    private

    def status
      output, _error, result = Open3.capture3("docker", "exec", @name, "tailscale", "status", "--json")
      result.success? ? JSON.parse(output) : {}
    end

    def command(*args, check: true)
      success = system(*args, out: $stderr)
      raise "Tailscale command failed: #{args.first(2).join(" ")}" if check && !success
      success
    end

    def authenticate(hostname, key)
      # Stdin and a short-lived tmpfs file keep the key out of argv and Docker metadata.
      script = <<~SH
        set -eu
        umask 077
        key_file=$(mktemp /dev/shm/dworkenv-auth.XXXXXX)
        trap 'rm -f "$key_file"' EXIT HUP INT TERM
        cat > "$key_file"
        tailscale up --hostname="$1" --accept-dns=false --timeout=30s --auth-key="file:$key_file"
      SH
      output, error, result = Open3.capture3(
        "docker", "exec", "-i", @name, "sh", "-ec", script, "dworkenv-auth", hostname,
        stdin_data: key + "\n",
      )
      raise "Tailscale key authentication failed: #{(output + error).gsub(key, "[redacted]").strip}" unless result.success?
    end
  end
end
