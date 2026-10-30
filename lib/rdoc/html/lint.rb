# frozen_string_literal: true

require 'cgi'
require 'net/http'
require 'set'
require 'uri'
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

        def run
          visited = Set.new
          found = Set.new
          pages = {}
          queue = [BASE_URL]


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

              page.response = response
              found << final_url

              content_type = response['content-type'].to_s
              next unless content_type.include?('text/html')

              pattern = /href\s*=\s*["']([^"']+)["']/i
              response.body.to_enum(:scan, pattern).map { Regexp.last_match }.each do |match|
                href = match[1]
                begin
                  uri = URI.join(final_url, href)

                  next unless uri.scheme == 'https'
                  next unless uri.host == 'docs.ruby-lang.org'
                  next unless uri.path.start_with?('/en/master')

                  uri.fragment = nil

                  link_url = uri.to_s
                  page.links << match

                  queue << link_url unless visited.include?(link_url)
                rescue URI::InvalidURIError
                  # Ignore malformed links.
                end
              end

            rescue StandardError => e
              fail "  #{e.class}: #{e.message}"
            end
          end

          puts "#{pages.size} pages found."

          pages.each do |url, page|
            page.links.each do |link|
              href = link[1]
              link_uri = URI.join(page.url, href)
              link_uri.fragment = nil
              link_url = link_uri.to_s
              next if found.include?(link_url)
              page.breaks << link
            end
          end
          pages.each do |url, page|
            next if page.breaks.empty?
            puts "Page #{url}"
            page.breaks.each do |link|
              link_url = link[1]
              link_lineno = link.pre_match.count("\n") + 1
              puts "  #{link_url}, line #{link_lineno}"
              p link
            end
          end

        end

        class Page

          attr_accessor :url, :links, :breaks, :response

          def initialize(url)
            self.url = url
            self.links = []
            self.breaks = []
          end

        end

        class Error < StandardError; end

      end
    end
  end
end
