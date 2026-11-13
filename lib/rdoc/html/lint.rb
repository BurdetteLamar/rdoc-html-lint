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

        attr_accessor :options

        def initialize(options= {})
          self.options = options
        end

        # Fetch each page from the website.
        # Put its HTML into a file in stashes/doc.
        # Extract the links to on-site pages and queue them for fetching.
        def fetch
          # Create a new doc directory (with a timestamp).
          doc_dir_path = Checker.new_doc_dirpath
          visited = Set.new   # Visit only once.
          found = Set.new     # Those that are found.
          queue = [BASE_URL]  # Prime with home page.
          page_count = 0
          while (url = queue.shift)
            next if visited.include?(url)
            next if BASE_URL == url + '/'
            puts "Fetching #{url}"
            begin
              response, final_url, _ = Checker.get(url)
              visited << final_url
              visited << url
              next unless FOUND_CODES.include?(response.code)
              found << final_url
              content_type = response['content-type'].to_s
              next unless content_type.include?('text/html')
              html = response.body
              write_html(html, url, doc_dir_path)
              page_count += 1
              links = Link.links(html)
              links.each do |link|
                begin
                  uri = URI.join(final_url, link.href)
                  # Must be one of ours.
                  next unless uri.scheme == 'https'
                  next unless uri.host == 'docs.ruby-lang.org'
                  next unless uri.path.start_with?('/en/master')
                  uri.fragment = nil # No fragment.
                  link_url = uri.to_s
                  queue << link_url unless visited.include?(link_url)
                rescue URI::InvalidURIError
                  # Ignore malformed link.
                end
              end
            rescue StandardError => e
              fail "  #{e.class}: #{e.message}"
            end
          end
          puts "Wrote #{page_count} files to #{doc_dir_path}"

        end

        # Write the captured HTML to a file in doc directory.
        def write_html(html, url, doc_dir_path)
          path = url.sub(BASE_URL, '')
          dirpath = File.join(doc_dir_path, File.dirname(path))
          filepath = File.join(dirpath, File.basename(path))
          FileUtils.mkdir_p(dirpath)
          if File.basename(filepath) == '.'
            filepath = File.join(File.dirname(filepath), 'home.html')
          end
          filepath = Pathname(filepath).cleanpath
          File.write(filepath, html)
        end

        # Make a JSON precis for each page.
        def precis
          timestamp_dirpath = Checker.last_timestamp_dirpath
          doc_dirpath = File.join(timestamp_dirpath, 'doc')
          precis_dirpath = File.join(timestamp_dirpath, 'precis')
          html_filepaths = Dir.glob("#{doc_dirpath}/**/*.html")
          pages = {}
          html_filepaths.each do |html_filepath|
            puts "Reading #{html_filepath}"
            html = File.read(html_filepath)
            path = html_filepath.sub(doc_dirpath + '/', '')
            page = Page.new(html, path)
            pages[path] = page
          end
          paths = pages.keys
          pages.each_pair do |path, page|
            Heading.check_page(page)
            Link.check_page(page, paths)
            precis = page.to_json
            precis_filepath = File.join(precis_dirpath, page.path).sub('.html', '.json')
            FileUtils.mkdir_p(File.dirname(precis_filepath))
            # puts "Writing #{precis_filepath}"
            File.write(precis_filepath, precis)
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

        # Create a directory for a new set of documents.
        def self.new_doc_dirpath
          time_s = Time.now.strftime('%Y-%m-%d-%a-%H.%M.%S')
          dirpath = File.join('stashes', time_s, 'doc')
          puts "Creating diretory #{dirpath}"
          FileUtils.mkdir_p(dirpath)
          dirpath
        end

        def self.last_timestamp_dirpath
          timestamp_dirpaths = []
          Dir.glob('stashes/*').select do |path|
            timestamp_dirpaths << path if File.directory?(path)
          end
          timestamp_dirpaths.sort.last
        end

      end

      class Page
        attr_accessor :html, :path, :links, :headings, :ids

        def initialize(html, path = nil)
          self.html = html
          self.path = path
          self.headings = Heading.headings(html)
          self.links = Link.links(html)
          self.ids = Id.ids(html)
        end

        def to_h
          {
            path: path,
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

        PATTERN = /\b(?<name>id|name)\s*=\s*(?:"(?<value>[^"]*)"|'(?<value>[^']*)'|(?<value>[^\s>]+))/i

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

        def self.ids(html)
          ids = {}
          matches = []
          html.to_enum(:scan, PATTERN).each { matches << Regexp.last_match }
          matches.each do |match|
            id = Id.new(match)
            ids[id.value] ||= id
          end
          ids
        end

        def to_h
          {name: name, value: value}
        end

      end

      class Link

        PATTERN = %r{
  <a\b
  [^>]*?
  href=(?<quote>['"])(?<href>.*?)\k<quote>
  [^>]*>
  (?<text>.*?)
  </a>
}imx

        attr_accessor :lineno, :href, :text, :status

        def initialize(object)
          case object
          when MatchData
            self.lineno = object.pre_match.count("\n") + 1
            self.href = object['href']
            self.text = object['text']
            self.status = 'unknown'
          when Hash
            self.lineno = object[:lineno]
            self.href = object[:href]
            self.text = object[:text]
            self.status = object[:status]
          else
            raise ArgumentError.new('Argument must be a MatchData or a Hash')
          end
        end

        def uri
          begin
            URI.parse(self.href)
          rescue URI::InvalidURIError
            nil
          end
        end

        def self.links(html)
          links = []
          matches = html.to_enum(:scan, PATTERN).map { Regexp.last_match }
          matches.each do |match|
            links << Link.new(match)
          end
          links
        end

        def self.check_page(page, paths)
          page.links.each do |link|
            href = link.href
            next unless href.start_with?('./')
            target_path = href.sub(%r[^\./], '')
            link.status = paths.include?(target_path) ? 'ok' : target_path
          end
        end

        def to_h
          {lineno: lineno, href: href, text: text, status: status}
        end
      end

      class Heading

        PATTERN = /<h(?<level>[1-6])\b[^>]*>(?<text>.*?)<\/h\k<level>\s*>/im

        attr_accessor :lineno, :level, :text, :status

        def initialize(object)
          case object
          when MatchData
            self.lineno = object.pre_match.count("\n") + 1
            self.level = object['level']
            self.text = object['text']
            self.status = 'unknown'
          when Hash
            self.lineno = object[:lineno]
            self.href = object[:level]
            self.text = object[:text]
            self.status = object[:status]
          else
            raise ArgumentError.new('Argument must be a MatchData or a Hash')
          end
        end

        def self.headings(html)
          matches = html.to_enum(:scan, PATTERN).map { Regexp.last_match }
          headings = []
          matches.each do |match|
            headings << Heading.new(match)
          end
          headings
        end

        def self.check_page(page)
          prev_level = 0
          page.headings.each_with_index do |heading, i|
            level = heading.level.to_i
            jump_size = level - prev_level
            if jump_size <= 1
              heading.status = 'Ok'
            else
              heading.status = "Bad jump: #{prev_level} to #{level}"
            end
            prev_level = level
          end
        end

        def to_h
          {lineno: lineno, level: level, text: text, status: status}
        end
      end

    end
  end
end
