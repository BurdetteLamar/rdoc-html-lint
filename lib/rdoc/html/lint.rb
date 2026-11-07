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

        attr_accessor :options

        def initialize(options)
          self.options = options
        end

        def self.external_url?(url)
          begin
            uri = URI.parse(url)
            uri.absolute? && !uri.host.nil?
          rescue URI::InvalidURIError
            return false
          end
        end

        def get(url, limit = 10)
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
            return [response, target, get(target, limit - 1)[2]]
          end

          [response, url, nil]
        end

        def refresh
          target_dir_path = File.basename(BASE_URL)
          visited = Set.new
          found = Set.new
          queue = [BASE_URL]
          require 'fileutils'
          FileUtils.rm_rf(target_dir_path)
          Dir.mkdir(target_dir_path)

          count = 0
          while (url = queue.shift)
            next if visited.include?(url)

            next if BASE_URL == url + '/'
            # puts url
            path = url.sub(BASE_URL, '')
            dirpath = File.join(target_dir_path, File.dirname(path))
            filepath = File.join(dirpath, File.basename(path))
            FileUtils.mkdir_p(dirpath)

            begin
              response, final_url, _ = get(url)
              visited << final_url
              visited << url

              next unless FOUND_CODES.include?(response.code)

              found << final_url

              content_type = response['content-type'].to_s
              next unless content_type.include?('text/html')

              html = response.body
              if File.basename(filepath) == '.'
                filepath = File.join(File.dirname(filepath), 'home.html')
              end
              filepath = Pathname(filepath).cleanpath
              puts "Writing #{filepath}"
              File.write(filepath, html)
              count += 1
              matches = Checker.links(html)
              matches.each do |match|
                href, text = match.values_at('href', 'text')
                begin
                  uri = URI.join(final_url, href)

                  next unless uri.scheme == 'https'
                  next unless uri.host == 'docs.ruby-lang.org'
                  next unless uri.path.start_with?('/en/master')

                  uri.fragment = nil

                  link_url = uri.to_s

                  queue << link_url unless visited.include?(link_url)
                rescue URI::InvalidURIError
                  # Ignore malformed links.
                end
              end

            rescue StandardError => e
              fail "  #{e.class}: #{e.message}"
            end
          end
          puts "Wrote #{count} files"

        end

        def self.links(html)
          pattern = %r{
  <a\b
  [^>]*?
  href=(?<quote>['"])(?<href>.*?)\k<quote>
  [^>]*>
  (?<text>.*?)
  </a>
}imx
          html.to_enum(:scan, pattern).map { Regexp.last_match }
        end
        def run
          refresh if options[:refresh]
          analyze if options[:analyze]
        end

        def analyze
          pages = {}
          paths = Dir.glob('**/*.html')
          paths.each do |path|
            html = File.read(path)
            page = Page.new(path, html)
            pages[path] = page
          end


          exit


          pages.each do |url, page|
            page.links.each do |link|
              href = link[:href]
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
              href, text = link.values_at('href', 'text')
              lineno = link.pre_match.count("\n") + 1
              puts "  text='#{text}' href='#{href}' lineno=#{lineno}"
            end
          end


        end

        class Page

          attr_accessor :html, :path, :links, :breaks

          def initialize(path, html)
            self.path = path
            self.html = html
            self.breaks = []
            self.links = path.start_with?('master/NEWS') ? [] : Checker.links(html)
            self.links.each do |link|
              href = link[:href]
              next if Checker.external_url?(href)
              next if href.start_with?('mailto:')
              target_path = File.join(File.dirname(path), href)
              target_path = Pathname(target_path).cleanpath.to_s
              target_path = target_path.split('#').first
              breaks << target_path unless File.exist?(target_path)
            end
            return if breaks.empty?
            puts path
            breaks.each do |_break|
              puts '  ' + _break
            end
          end

        end

        class Error < StandardError; end

      end
    end
  end
end
