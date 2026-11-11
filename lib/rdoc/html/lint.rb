# frozen_string_literal: true

require 'cgi'
require 'fileutils'
require 'json'
require 'net/http'
require 'set'
require 'uri'
require_relative "lint/version"

module Rdoc
  module Html
    module Lint
      class Checker

        # The home page for Ruby documents.
        BASE_URL = 'https://docs.ruby-lang.org/en/master/'
        # Redirection codes.
        REDIRECT_CODES = %w[301 302 303 307 308]
        # Happy code.
        OK_CODE = ['200']
        # Both.
        FOUND_CODES = OK_CODE + REDIRECT_CODES

        # Options (usually from the CLI).
        attr_accessor :options

        def initialize(options= {})
          self.options = options
        end

        # Fetch each page from the website.
        # Put its HTML into a file in stashes/doc.
        # Extract the links to on-site pages and queue them for fetching.
        def fetch
          doc_dir_path = File.join('stashes', Checker.timestamp, 'doc')
          visited = Set.new
          found = Set.new
          queue = [BASE_URL]
          FileUtils.mkdir_p(doc_dir_path)
          puts "Creating diretory #{doc_dir_path}"

          page_count = 0
          while (url = queue.shift)
            next if visited.include?(url)

            next if BASE_URL == url + '/'
            puts "Fetching #{url}"
            path = url.sub(BASE_URL, '')
            dirpath = File.join(doc_dir_path, File.dirname(path))
            filepath = File.join(dirpath, File.basename(path))
            FileUtils.mkdir_p(dirpath)

            begin
              response, final_url, _ = Checker.get(url)
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
              File.write(filepath, html)
              page_count += 1

              page = Page.new(html)

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
          puts "Wrote #{page_count} files to #{doc_dir_path}"

        end

        # Make a JSON precis for each page.
        def precis
          timestamp_dirpath = Checker.last_timestamp_dirpath
          doc_dirpath = File.join(timestamp_dirpath, 'doc')
          precis_dirpath = File.join(timestamp_dirpath, 'precis')
          html_filepaths = Dir.glob("#{doc_dirpath}/**/*.html")
          html_filepaths.each do |html_filepath|
            html = File.read(html_filepath)
            page = Page.new(html)
            precis = page.to_json
            precis_filepath = html_filepath.sub(doc_dirpath, precis_dirpath)
            precis_filepath.sub!('.html', '.json')
            FileUtils.mkdir_p(File.dirname(precis_filepath))
            puts "Writing #{precis_filepath}"
            File.write(precis_filepath,   precis)
          end
        end

        # def analyze
        #   # Gather the pages.0
        #   # Sources are in the most-recent stash of the docs.
        #   stash_dir = Dir.glob("stashes/*/").sort.last
        #   source_dir = File.join(stash_dir, 'doc')
        #   puts "Analyzing #{source_dir}"
        #   pages = {} # Pages, by path.
        #   paths = Dir.glob("#{source_dir}/*.html")
        #   paths.each do |path|
        #     puts "Checking #{path}"
        #     html = File.read(path)
        #     page = Page.new(path, html)
        #     pages[path] = page
        #   end
        #
        #   pages.each do |path, page|
        #     page.links.each do |link|
        #       href = link[:href]
        #       p [page.path, href]
        #       link_uri = URI.join(File.dirname(page.path), href)
        #       link_uri.fragment = nil
        #       link_url = link_uri.to_s
        #       next if found.include?(link_url)
        #       page.breaks << Break.new(link)
        #     end
        #   end
        #   pages.each do |url, page|
        #     next if page.breaks.empty?
        #     puts "Page #{url}"
        #     page.breaks.each do |link|
        #       href, text = link.values_at('href', 'text')
        #       lineno = link.pre_match.count("\n") + 1
        #       puts "  text='#{text}' href='#{href}' lineno=#{lineno}"
        #     end
        #   end
        # end



        # Return whether the URL is off-site (or invalid).
        def self.external_url?(url)
          begin
            uri = URI.parse(url)
            uri.absolute? && !uri.host.nil?
          rescue URI::InvalidURIError
            return true
          end
        end

        # Get a page from the web; up to 10 redirects.
        # Return the response and the URL.
        def self.get(url, redirect_limit = 10)
          raise 'too many redirects' if redirect_limit.zero?

          # Make a URI and Net::HTTP.
          uri = URI(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == 'https')
          http.open_timeout = 30
          http.read_timeout = 60
          # Get the page.
          request = Net::HTTP::Get.new(uri.request_uri)
          request['User-Agent'] = 'Ruby documentation crawler'
          response = http.request(request)
          # Check for redirection.
          if REDIRECT_CODES.include?(response.code)
            location = response['location']
            raise "redirect without Location header" unless location

            target = URI.join(url, location).to_s
            # Get using the redirection.
            return [response, target, self.get(target, redirect_limit - 1)[2]]
          end
          [response, url, nil]
        end

        # Timestamp for directory for the fetched docs and associated files.
        def self.timestamp
          Time.now.strftime('%Y-%m-%d-%a-%H.%M.%S')
        end

        def self.last_timestamp_dirpath

          timestamp_dirpaths = []
          Dir.glob('stashes/*').select do |path|
            timestamp_dirpaths << path if File.directory?(path)
          end
          timestamp_dirpaths.sort.last
        end

        def self.ids(html)
          matches = []
          html.to_enum(:scan, /\b(?<name>id|name)\s*=\s*(?:"(?<value>[^"]*)"|'(?<value>[^']*)'|(?<value>[^\s>]+))/i)
              .each { matches << Regexp.last_match }
          matches
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

        def self.headings(html)
          pattern = /<h(?<level>[1-6])\b[^>]*>(?<text>.*?)<\/h\k<level>\s*>/im
          html.to_enum(:scan, pattern).map { Regexp.last_match }
        end
      end

      class Page
        attr_accessor :html, :links, :headings, :ids

        def initialize(html)
          self.html = html
          self.headings = []
          self.links = []
          self.ids = {}
          matches = Checker.links(html)
          matches.each do |match|
            self.links << Link.new(match)
          end
          matches = Checker.headings(html)
          matches.each do |match|
            self.headings << Heading.new(match)
          end
          matches = Checker.ids(html)
          matches.each do |match|
            id = Id.new(match)
            ids[id.value] ||= id
          end
        end

        def to_h
          {
            links: links.map(&:to_h),
            headings: headings.map(&:to_h),
            ids: ids.transform_values(&:to_h)
          }
        end


        def to_json
          JSON.pretty_generate(to_h)
        end

      end

      class Id

        attr_accessor :name, :value

        def initialize(object)
          case object
          when MatchData
            self.name = object[:name]
            self.value = object[:value]
          when Hash
            self.name = object[:name]
            self.value = object[:value]
          else
            raise ArgumentError.new('Argument must be a MatchData or a Hash')
          end
        end

        def to_h
          {name: name, value: value}
        end

      end

      class Link
        attr_accessor :lineno, :href, :text
        def initialize(object)
          case object
          when MatchData
            self.lineno = object.pre_match.count("\n") + 1
            self.href = object['href']
            self.text = object['text']
          when Hash
            self.lineno = object[:lineno]
            self.href = object[:href]
            self.text = object[:text]
          else
            raise ArgumentError.new('Argument must be a MatchData or a Hash')
          end
        end

        def to_h
          {lineno: lineno, href: href, text: text}
        end
      end

      class Heading
        attr_accessor :lineno, :level, :text
        def initialize(object)
          case object
          when MatchData
            self.lineno = object.pre_match.count("\n") + 1
            self.level = object['level']
            self.text = object['text']
          when Hash
            self.lineno = object[:lineno]
            self.href = object[:level]
            self.text = object[:text]
          else
            raise ArgumentError.new('Argument must be a MatchData or a Hash')
          end
        end

        def to_h
          {lineno: lineno, level: level, text: text}
        end
      end

    end
  end
end
