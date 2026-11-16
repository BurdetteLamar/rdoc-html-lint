# frozen_string_literal: true

require 'cgi'
require 'fileutils'
require 'json'
require 'net/http'
require 'rexml/document'
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

        # Download and store each HTML page from the website.
        # Extract the links to on-site pages and queue them for fetching.
        def download
          snapshot = Snapshot.new(:new)
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
              path = url.sub(BASE_URL, '')
              unless path.empty? # Don't write the home page.
                snapshot.write_html(path, html)
              end

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
          puts "Wrote #{page_count} files to #{snapshot.html_dirpath}"

        end

        # Evaluate each HTML file.
        def evaluate
          snapshot = Snapshot.new(:latest)
          pages = {}
          paths = snapshot.html_paths
          paths.each do |path|
            html = snapshot.read_html(path)
            page = Page.new(html)
            pages[path] = page
          end
          pages.each_pair do |path, page|
            Heading.check_page(page)
            Link.check_page(page, paths)
            snapshot.write_evaluation(path, page)
          end
        end

        # Create a report.
        def report
          snapshot = Snapshot.new(:latest)
          pages = {}
          paths = snapshot.evaluation_paths
          paths.each do |path|
            json = snapshot.read_evaluation(path)
            hash = JSON.parse(json)
            page = Page.new(hash)
            pages[path] = page
          end
          lines = []
          pages.each_pair do |path, page|
            page.links.each do |link|
              next if link.status == 'unknown'
              p link unless link.status == 'ok'
            end
            page.headings.each do |heading|
              # Bug in RDoc itself causes this (on every page).
              heading.errors.shift if heading.errors.first == "Bad jump: 1 to 3."
              unless heading.errors.empty? && heading.warnings.empty?
                lines << "Page #{path} heading:"
                level, lineno, text = heading.to_h.values_at(:level, :lineno, :text)
                lines << "  Level: #{level}"
                lines << "  Lineno: #{lineno}"
                lines << "  Text: '#{text}'"
                heading.errors.each do |error|
                  lines << "    Error: #{error}"
                end
                heading.warnings.each do |warning|
                  lines << "    Warning: #{warning}"
                end
              end
            end
          end
          report = lines.join("\n")
          snapshot.write_report(report)

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

      end

      class Page
        attr_accessor :html, :path, :links, :headings, :ids

        def initialize(object, path = nil)
          case object
          when String
            html = object
            self.html = html
            self.path = path
            self.headings = Heading.headings(html)
            self.links = Link.links(html)
            self.ids = Id.ids(html)
          when Hash
            self.path = object['path']
            self.headings = []
            object['headings'].each do |heading|
              self.headings << Heading.new(heading)
            end
            self.links = []
            object['links'].each do |link|
              self.links << Link.new(link)
            end
            self.ids = {}
            object['ids'].each_pair do |id, data|
              self.ids[id] = Id.new(data)
            end
          else
            raise ArgumentError.new('Argument must be a String or a Hash')
          end
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

        attr_accessor :lineno, :href, :text, :status, :type

        def initialize(object)
          case object
          when MatchData
            self.lineno = object.pre_match.count("\n") + 1
            self.href = object['href']
            self.text = object['text']
            self.status = 'unknown'
            self.type = get_type
          when Hash
            self.lineno = object['lineno']
            self.href = object['href']
            self.text = object['text']
            self.status = object['status']
            self.type = object['type']
          else
            raise ArgumentError.new('Argument must be a MatchData or a Hash')
          end
        end

        def get_type
          uri = get_uri
          char = href[0]
          case
          when uri.nil?
            'invalid'  # Junk.
          when !uri.scheme.nil?
            'offsite'  # Offsite.
          when char == '.'
            'relative' # Relative to containing age.
          when char == '#'
            'fragment' # Free fragment.
          when ('A'..'Z').include?(char)
            'class'    # Class or module.
          when ('a'..'z').include?(char)
            'file'     # Ruby file.
          else
            message = "Couldn't determine link type for #{href}."
            raise RuntimeError.new(message)
          end
        end

        def get_uri
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
            link.status = paths.include?(target_path) ? 'ok' : 'not found'
          end
        end

        def to_h
          {lineno: lineno, href: href, text: text, status: status, type: type}
        end
      end

      class Heading

        PATTERN = /<h(?<level>[1-6])\b[^>]*>(?<text>.*?)<\/h\k<level>\s*>/im

        attr_accessor :lineno, :level, :text, :errors, :warnings

        def initialize(object)
          case object
          when MatchData
            self.lineno = object.pre_match.count("\n") + 1
            self.level = object['level']
            text_ = object['text']
            xml = "<root>#{text_}</root>"
            doc = REXML::Document.new(xml)
            root = doc.root
            elements = root.elements
            case elements.size
            when 0
              self.text = root.text.to_s
            when 1
              self.text = elements.first.text
            when 2
              elements.each_with_index do |element, i|
                next unless element.attributes['class'] == 'page-title-name'
                self.text = element.text
              end
            else
              raise RuntimeError.new("Cannot handle heading '#{text_}'")
            end
            self.errors = []
            self.warnings = []
          when Hash
            self.lineno = object['lineno']
            self.level = object['level']
            self.text = object['text']
            self.errors = object['errors']
            self.warnings = object['warnings']
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
            if (i == 0) && (level != 1)
              heading.warnings << "First heading should be level 1, not #{level}."
            end
            jump_size = level - prev_level
            if jump_size > 1
              heading.errors << "Bad jump: #{prev_level} to #{level}."
            end
            prev_level = level
          end
        end

        def to_h
          {lineno: lineno, level: level, text: text, errors: errors, warnings: warnings}
        end
      end

      # Class to handle snapshots in an orderly manner.
      class Snapshot

        # Paths and file extensions.
        SNAPSHOT_DIRNAME = 'snapshot'
        HTML_DIRNAME,       HTML_EXTENSION =       %w[html       .html]
        EVALUATION_DIRNAME, EVALUATION_EXTENSION = %w[evaluation .json]
        REPORT_DIRNAME,     REPORT_EXTENSION =     %w[report     .txt]

        # The directory paths.
        attr_accessor :timestamp_dirpath,
                      :html_dirpath,
                      :evaluation_dirpath,
                      :report_dirpath

        # Return a new Path object with an established timestamp directory.
        def initialize(which)
          valid_args = %i[new latest]
          unless valid_args.include?(which)
            message = "Argument which must be one of #{valid_args.inspect}."
            raise ArgumentError.new(message)
          end
          if which == :new
            # Create new timestamp directory.
            timestamp = Time.now.strftime('%Y-%m-%d-%a-%H.%M.%S')
            self.timestamp_dirpath = File.join(SNAPSHOT_DIRNAME, timestamp)
          else
            # Find latest timestamp directory.
            dirpaths = []
            glob = File.join(SNAPSHOT_DIRNAME, '**')
            Dir.glob(glob).select do |path|
              dirpaths << path if File.directory?(path)
            end
            self.timestamp_dirpath = dirpaths.sort.last
          end
          # Set the other dirpaths.
          self.html_dirpath = File.join(self.timestamp_dirpath, HTML_DIRNAME)
          self.evaluation_dirpath = File.join(self.timestamp_dirpath, EVALUATION_DIRNAME)
          self.report_dirpath = File.join(self.timestamp_dirpath, REPORT_DIRNAME)
          if which == :new
            # Create the directories.
            FileUtils.mkdir_p(self.timestamp_dirpath)
            FileUtils.mkdir_p(self.html_dirpath)
            FileUtils.mkdir_p(self.evaluation_dirpath)
            FileUtils.mkdir_p(self.report_dirpath)
          end
        end

        def html_paths
          filepaths = []
          glob = File.join('**', '*' + HTML_EXTENSION)
          Dir.glob(glob, base: html_dirpath).select do |path|
            filepaths << path if File.extname(path) == HTML_EXTENSION
          end
          filepaths
        end

        def html_filepath(path)
          filepath = path.sub(File.extname(path), HTML_EXTENSION)
          File.join(html_dirpath, filepath)
        end

        def write_html(path, html)
          filepath = html_filepath(path)
          file_dirpath = File.dirname(filepath)
          if file_dirpath != html_dirpath
            FileUtils.mkdir_p(file_dirpath)
          end
          puts "Writing #{filepath}"
          File.write(filepath, html)
        end

        def read_html(path)
          filepath = html_filepath(path)
          puts "Reading #{filepath}"
          File.read(filepath)
        end

        def evaluation_paths
          filepaths = []
          glob = File.join('**', '*' + EVALUATION_EXTENSION)
          Dir.glob(glob, base: evaluation_dirpath).select do |path|
            filepaths << path if File.extname(path) == EVALUATION_EXTENSION
          end
          filepaths
        end

        def evaluation_filepath(path)
          filepath = path.sub(File.extname(path), EVALUATION_EXTENSION)
          File.join(evaluation_dirpath, filepath)
        end

        def write_evaluation(path, page)
          json = page.to_json
          filepath = evaluation_filepath(path)
          file_dirpath = File.dirname(filepath)
          if file_dirpath != html_dirpath
            FileUtils.mkdir_p(file_dirpath)
          end
          puts "Writing #{filepath}"
          File.write(filepath, json)
        end

        def read_evaluation(path)
          filepath = evaluation_filepath(path)
          puts "Reading #{filepath}"
          File.read(filepath)
        end

        def write_report(report)
          filepath = File.join(report_dirpath, 'Report.txt')
          puts "Writing #{filepath}"
          File.write(filepath, report)
        end

      end
    end
  end
end
