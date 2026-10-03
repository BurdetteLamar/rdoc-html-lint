# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'set'

require_relative "lint/version"

module Rdoc
  module Html
    module Lint
      class Checker

        BASE_URL = 'https://docs.ruby-lang.org/en/master/'
        REDIRECT_CODES = %w[301 302 303 307 308]
        OK_CODE = ['200']
        FOUND_CODES = OK_CODE + REDIRECT_CODES


        def initialize

        end

        def run
          visited = Set.new
          found = Set.new
          pages = {}
          queue = [BASE_URL]

          def fetch(url, limit = 10)
            raise 'too many redirects' if limit.zero?

            uri = URI(url)

            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == 'https')
            http.open_timeout = 10
            http.read_timeout = 30

            request = Net::HTTP::Get.new(uri.request_uri)
            request['User-Agent'] = 'Ruby documentation crawler'

            response = http.request(request)

            if REDIRECT_CODES.include?(response.code)
              location = response['location']
              raise "redirect without Location header" unless location

              target = URI.join(url, location).to_s
              return [response, target, fetch(target, limit - 1)[2]]
            end

            [response, url, nil]
          end

          while (url = queue.shift)
            next if visited.include?(url)

            page = pages[url]
            unless page
              page = Page.new(url)
              pages[url] = page
            end

            puts url

            begin
              response, final_url, _ = fetch(url)
              visited << final_url
              visited << url

              next unless FOUND_CODES.include?(response.code)

              found << url

              content_type = response['content-type'].to_s
              next unless content_type.include?('text/html')

              response.body.scan(/href\s*=\s*["']([^"']+)["']/i).flatten.each do |href|
                begin
                  link = URI.join(final_url, href)

                  next unless link.scheme == 'https'
                  next unless link.host == 'docs.ruby-lang.org'
                  next unless link.path.start_with?('/en/master')

                  link.fragment = nil

                  link = link.to_s
                  page.links << link

                  queue << link unless visited.include?(link)
                rescue URI::InvalidURIError
                  # Ignore malformed links.
                end
              end

            rescue StandardError => e
              fail "  #{e.class}: #{e.message}"
            end
          end

          breaks = []
          pages.each do |url, page|
            page.links.each do |link|
              breaks << [url, link] unless found.include?(link)
            end
          end
          if breaks.empty?
            puts "No breaks found."
          else
            puts "#{breaks.size} breaks found."
            breaks.each do |url, link|
              puts "Source:  #{url}"
              puts "Target:  #{link}"
            end
          end

        end

        class Page

          attr_accessor :url, :links

          def initialize(url)
            self.url = url
            self.links = []

          end
        end

        class Error < StandardError; end

      end
    end
  end
end
