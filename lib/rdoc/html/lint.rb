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

        # # Write the captured HTML to a file in doc directory.
        # def write_html(html, url, doc_dir_path)
        #   path = url.sub(BASE_URL, '')
        #   dirpath = File.join(doc_dir_path, File.dirname(path))
        #   filepath = File.join(dirpath, File.basename(path))
        #   FileUtils.mkdir_p(dirpath)
        #   if File.basename(filepath) == '.'
        #     filepath = File.join(File.dirname(filepath), 'home.html')
        #   end
        #   filepath = Pathname(filepath).cleanpath
        #   File.write(filepath, html)
        # end

        # Make a JSON evaluation for each page.
        def evaluate
          timestamp_dirpath = Checker.last_timestamp_dirpath
          doc_dirpath = File.join(timestamp_dirpath, 'html')
          evaluation_dirpath = File.join(timestamp_dirpath, 'evaluation')
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
            evaluation = page.to_json
            evaluation_filepath = File.join(evaluation_dirpath, page.path).sub('.html', '.json')
            FileUtils.mkdir_p(File.dirname(evaluation_filepath))
            # puts "Writing #{evaluation_filepath}"
            File.write(evaluation_filepath, evaluation)
          end
        end

        # Make a report for each page.
        def report
          timestamp_dirpath = Checker.last_timestamp_dirpath
          evaluation_dirpath = File.join(timestamp_dirpath, 'evaluation')
          report_dirpath = File.join(timestamp_dirpath, 'report')
          json_filepaths = Dir.glob("#{evaluation_dirpath}/**/*.json")
          pages = {}
          json_filepaths.each do |json_filepath|
            puts "Reading #{json_filepath}"
            "Reading #{json_filepath}"
            json = File.read(json_filepath)
            path = json_filepath.sub(evaluation_dirpath + '/', '')
            hash = JSON.parse(json)
            page = Page.new(hash, path)
            pages[path] = page
          end
          pages.each_pair do |path, page|
            report_filepath = File.join(report_dirpath, page.path).sub('.html', '.txt')
            puts "Creating #{report_dirpath}"
            FileUtils.mkdir_p(report_dirpath)
            s = ''
            puts "Writing #{report_filepath}"
            File.write(report_filepath, s)
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

      end

      class Page
        attr_accessor :html, :path, :links, :headings, :ids

        def initialize(object, path = nil)
          case object
          when String
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
            self.lineno = object[:lineno]
            self.href = object[:href]
            self.text = object[:text]
            self.status = object[:status]
            self.type = object[:type]
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
            link.status = paths.include?(target_path) ? 'ok' : target_path
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
            self.text = object['text']
            self.errors = []
            self.warnings = []
          when Hash
            self.lineno = object[lineno]
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
            timestamp_dirpaths = []
            Dir.glob("#{SNAPSHOT_DIRNAME}/*").select do |path|
              timestamp_dirpaths << path if File.directory?(path)
            end
            self.timestamp_dirpath = timestamp_dirpaths.sort.last
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
          File.read(html_filepath(path))
        end

        def evaluation_filepath(path)
          filename = File.basename(path, File.extname(path)) + EVALUATION_EXTENSION
          File.join(evaluation_dirpath, filename)
        end

        def write_evaluation(path)
          File.write(evaluation_filepath(path), evaluation)
        end

        def read_evaluation(path)
          File.read(evaluation_filepath(path))
        end

        def report_filepath(path)
          filename = File.basename(path, File.extname(path)) + report_EXTENSION
          File.join(report_dirpath, filename)
        end

        def write_report(path)
          File.write(report_filepath(path), report)
        end

        def read_report(path)
          File.read(report_filepath(path))
        end

      end
    end
  end
end
