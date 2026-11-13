# frozen_string_literal: true

require "digest"
require "json"
require "set"

module Dworkenv
  class PreviewAssets
    EXCLUDED = %w[node_modules .git dist tmp log coverage .cache .bundle .devenv gems auto_generated].freeze
    SOURCE_DIRECTORIES = %w[app bin config frontend lib plugins public/javascripts script vendor/assets].freeze

    def self.snapshot(root = ".")
      digest = Digest::SHA256.new.update("preview-assets-v1\0")
      visit = lambda do |relative, ancestors|
        next if EXCLUDED.include?(File.basename(relative)) || relative.end_with?(".tsbuildinfo")
        path = File.join(root, relative)
        if File.directory?(path)
          real = File.realpath(path)
          next if ancestors.include?(real)
          Dir.children(path).sort.each { |child| visit.call(File.join(relative, child), ancestors | [real]) }
        elsif File.file?(path)
          digest.update(relative).update("\0").update(Digest::SHA256.file(path).hexdigest).update("\0")
        end
      end
      SOURCE_DIRECTORIES.each { |path| visit.call(path, Set.new) }
      Dir.children(root).sort.each do |path|
        if File.file?(File.join(root, path)) && path.match?(/\.(json|ya?ml|[cm]?js|lock)\z|\AGemfile\z/)
          visit.call(path, Set.new)
        end
      end
      dist = File.join(root, "frontend/discourse/dist")
      manifest_path = File.join(dist, "manifest/manifest.json")
      complete = false
      manifest_hash = nil
      begin
        manifest = JSON.parse(File.read(manifest_path))
        raise KeyError unless manifest.is_a?(Hash) && manifest["chunks"].is_a?(Hash) && manifest["entrypoints"].is_a?(Hash)
        chunks = manifest.fetch("chunks").keys
        complete = manifest.fetch("entrypoints").key?("discourse") && !chunks.empty? &&
          chunks.all? { |path| File.file?(File.join(dist, path)) }
        manifest_hash = Digest::SHA256.file(manifest_path).hexdigest
      rescue Errno::ENOENT, JSON::ParserError, KeyError
      end
      { "source" => digest.hexdigest, "manifest" => manifest_hash, "complete" => complete }
    end

    def self.reusable?(current, previous)
      current["complete"] && current == previous
    end
  end
end
