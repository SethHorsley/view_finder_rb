Gem::Specification.new do |spec|
  spec.name = "view_finder"
  spec.version = "0.1.0"
  spec.authors = ["Your Name"]
  spec.email = ["your.email@example.com"]

  spec.summary = "A gem to find ERB partials in Rails views."
  spec.description = "This gem analyzes a Rails application's views and determines all partials rendered by a given view."
  spec.homepage = "https://your-gem-homepage.com"
  spec.license = "MIT"

  spec.files = Dir["lib/**/*", "bin/**/*", "README.md"]
  spec.bindir = "bin"
  spec.executables = ["view_finder"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 6.0"

  # Specify any additional runtime dependencies here.
end
