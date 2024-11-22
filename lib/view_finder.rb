require "rails"
require "rails/application"
require "action_controller/railtie"
require "pathname"

module ViewFinder
  class Finder
    PARTIAL_PATTERN = /<%=\s*render\s+(?:partial:\s*)?['"]([^'"]+)['"]/

    def initialize(options = {})
      @rails_root = find_rails_root
      raise "Not in a Rails application!" unless @rails_root

      @view_paths = [@rails_root.join("app/views")]
      @processed_files = Set.new
      @options = options
      @collected_partials = []

      load_rails_environment
    end

    def find_partials(view_path)
      return [] if @processed_files.include?(view_path)

      @processed_files.add(view_path)
      results = []

      begin
        full_path = find_template_path(view_path)
        return [] unless full_path && File.exist?(full_path)

        content = File.read(full_path)

        # If we're not processing partials, just return the main template
        if @options[:partials] == false
          return [format_content(full_path, content)]
        end

        # Process the content and replace partial references inline
        if @options[:embed] != false
          content = process_partials_inline(content, full_path)
        else
          # Collect partials and append them at the end
          partial_paths = content.scan(PARTIAL_PATTERN).flatten
          results << format_content(full_path, content)

          partial_paths.each do |partial_path|
            process_partial(partial_path, full_path, results)
          end

          return results
        end

        [format_content(full_path, content)]
      rescue => e
        puts "Error processing #{view_path}: #{e.message}"
        []
      end
    end

    def process_partials_inline(content, template_path)
      content.gsub(/<%=\s*render\s+(?:partial:\s*)?['"]([^'"]+)['"]([^%]*?)\s*%>/m) do |match|
        partial_path = $1.strip
        options_str = $2.to_s.strip

        # Extract locals if present
        locals_info = if options_str =~ /locals:\s*{(.*?)}/m
          ", locals: { #{$1.strip} }"
        else
          ""
        end

        # If path contains any slashes or starts with slash, treat it as absolute from app/views
        if partial_path.include?("/") || partial_path.start_with?("/")
          normalized_path = normalize_partial_path(partial_path)
          partial_full_path = find_partial_path(normalized_path)
        else
          current_template_dir = File.dirname(template_path.to_s.sub(@rails_root.join("app/views/").to_s, ""))
          normalized_path = normalize_partial_path(partial_path)
          partial_full_path = find_partial_path(normalized_path, current_template_dir)
        end

        if partial_full_path && File.exist?(partial_full_path)
          partial_content = File.read(partial_full_path)
          relative_path = Pathname.new(partial_full_path).relative_path_from(@rails_root)

          # Debug output
          # puts "Partial: #{partial_path}"
          # puts "Options: #{options_str}"
          # puts "Locals: #{locals_info}"

          "\n<!-- BEGIN PARTIAL: #{relative_path}#{locals_info} -->\n" +
            process_partials_inline(partial_content, partial_full_path) +
            "\n<!-- END PARTIAL: #{relative_path} -->\n"
        else
          puts "Warning: Could not find partial: #{normalized_path}"
          match # Keep original partial reference if not found
        end
      end
    end

    def find_partial_path(partial_name, current_template_path = nil)
      # Extract directory and filename parts
      File.dirname(partial_name)
      partial_basename = File.basename(partial_name)

      # Remove leading underscore if present, we'll add it back
      partial_basename = partial_basename.gsub(/^_+/, "")  # Remove any leading underscores
      partial_basename = "_#{partial_basename}"  # Always add one underscore

      # Build the partial path
      partial_path = if partial_name.include?("/") || partial_name.start_with?("/")
        # For paths with slashes or starting with slash, treat as absolute from app/views
        # Remove leading slash if present
        clean_path = partial_name.start_with?("/") ? partial_name[1..] : partial_name
        partial_dir = File.dirname(clean_path)
        File.join(partial_dir, partial_basename)
      else
        # For simple names without slashes, use the current template directory
        template_dir = current_template_path || "."
        File.join(template_dir, partial_basename)
      end

      possible_paths = [
        File.join(@rails_root, "app/views", partial_path + ".html.erb"),
        File.join(@rails_root, "app/views", partial_path + ".erb"),
        File.join(@rails_root, "app/views", partial_path + ".builder"),
        File.join(@rails_root, "app/views", partial_path + ".slim")
      ].map { |p| Pathname.new(p) }

      # puts "Searching for partial in paths:"
      possible_paths.each do |path|
        # puts "  - #{path}"
        return path if File.exist?(path)
      end
      nil
    end

    def process_partial(partial_path, template_path, results)
      clean_path = partial_path.strip.gsub(/['"]/, "")
      normalized_path = normalize_partial_path(clean_path)
      current_template_dir = File.dirname(template_path.to_s.sub(@rails_root.join("app/views/").to_s, ""))
      partial_full_path = find_partial_path(normalized_path, current_template_dir)

      if partial_full_path && File.exist?(partial_full_path)
        partial_content = File.read(partial_full_path)
        results << format_content(partial_full_path, partial_content)

        # Process nested partials
        nested_partial_paths = partial_content.scan(PARTIAL_PATTERN).flatten
        nested_partial_paths.each do |nested_path|
          process_partial(nested_path, partial_full_path, results)
        end
      else
        puts "Warning: Could not find partial: #{normalized_path}"
      end
    end

    def find_partials_from_route(route_input, namespace: nil)
      controller, action = find_controller_action(route_input, namespace: namespace)
      return [] unless controller && action

      view_path = controller_path_to_view_path(controller, action)
      find_partials(view_path)
    end

    private

    def extract_partial_paths(content)
      content.scan(PARTIAL_PATTERN).map(&:first)
    end

    def find_rails_root
      current_dir = Pathname.new(File.expand_path("."))

      while current_dir.to_s != "/"
        if File.exist?(current_dir.join("config/application.rb"))
          return current_dir
        end
        current_dir = current_dir.parent
      end

      nil
    end

    def load_rails_environment
      require File.expand_path("config/environment", @rails_root)
    end

    def find_controller_action(route_input, namespace: nil)
      Rails.application.routes.routes.each do |route|
        match = match_route?(route, route_input, namespace: namespace)
        return [match[:controller], match[:action]] if match
      end
      nil
    end

    def match_route?(route, route_input, namespace: nil)
      return unless route.path.spec.to_s.present?

      if namespace && route.defaults[:controller]
        controller_namespace = route.defaults[:controller].split("/")[0]
        return unless controller_namespace == namespace.to_s
      end

      # Check for the route matching exactly, with '_path', or with '_url'
      if route.name &&
          (route_input == route.name.to_s ||
            route_input == "#{route.name}_path" ||
            route_input == "#{route.name}_url")
        # puts "Matched route: #{route.defaults[:controller]}##{route.defaults[:action]}" # Debug
        return {controller: route.defaults[:controller], action: route.defaults[:action]}
      end

      nil
    end

    def build_args(route_input)
      route_input_params = /(\d+)/.match(route_input)
      route_input_params ? {id: route_input_params[1]} : {}
    end

    def controller_path_to_view_path(controller, action)
      "#{controller}/#{action}"
    end

    def find_template_path(view_path)
      absolute_path = @rails_root.join(view_path)
      return absolute_path if File.exist?(absolute_path)

      @view_paths.each do |view_root|
        possible_paths = [
          view_root.join(view_path),  # Attempt with direct relative path
          view_root.join("#{view_path}.html.erb"),
          view_root.join("#{view_path}.erb"),
          view_root.join("#{view_path}.builder"),
          view_root.join("#{view_path}.slim")
        ]
        possible_paths.each do |path|
          return path if File.exist?(path)
        end
      end
      nil
    end

    def normalize_partial_path(partial_path)
      # Remove leading slash if present
      partial_path = partial_path[1..] if partial_path.start_with?("/")
      # Remove any leading underscores - they'll be added back in find_partial_path
      partial_path.gsub(/^_+/, "")
    end

    def format_content(file_path, content)
      relative_path = Pathname.new(file_path).relative_path_from(@rails_root)
      formatted = "\n<!-- BEGIN TEMPLATE: #{relative_path} -->\n"
      formatted += prettify_erb(content)
      formatted += "\n<!-- END TEMPLATE: #{relative_path} -->\n"
      formatted
    end

    def prettify_erb(content)
      # Split content into lines and add proper indentation
      lines = content.split("\n")
      indent_level = 0
      lines.map do |line|
        # Decrease indent for closing tags
        indent_level -= 1 if line.strip =~ /<\/.*>$/ || line.strip =~ /\s*end\s*$/

        # Add indentation
        indented_line = "  " * [0, indent_level].max + line.strip

        # Increase indent for opening tags
        indent_level += 1 if line =~ /<[^\/][^>]*>$/ || line =~ /\s*do\s*(\|.*\|)?\s*$/

        indented_line
      end.join("\n")
    end
  end

  def self.find(view_path_or_route, options = {})
    finder = Finder.new(options)
    rails_root_path = finder.instance_variable_get(:@rails_root).join(view_path_or_route)

    results = if File.exist?(rails_root_path)
      finder.find_partials(rails_root_path)
    else
      finder.find_partials_from_route(view_path_or_route, namespace: options[:namespace])
    end

    result = results.join("")

    puts result
    result
  end
end
