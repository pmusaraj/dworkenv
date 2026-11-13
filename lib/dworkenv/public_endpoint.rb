# frozen_string_literal: true

require "uri"

module Dworkenv
  class PublicEndpoint
    attr_reader :uri

    def initialize(value)
      @uri = URI(value)
      unless %w[http https].include?(@uri.scheme) &&
          @uri.host&.match?(/\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/) &&
          @uri.port.between?(1, 65_535) && !@uri.userinfo &&
          ["", "/"].include?(@uri.path) && !@uri.query && !@uri.fragment
        raise ArgumentError, "Public URL must be an HTTP(S) origin with a hostname and optional port"
      end
      @uri.path = ""
    rescue URI::InvalidURIError
      raise ArgumentError, "Invalid public URL"
    end

    def hostname
      @uri.host
    end

    def https?
      @uri.scheme == "https"
    end

    def to_s
      @uri.to_s
    end
  end
end
