
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "shopify_api/graphql/tiny/version"

Gem::Specification.new do |spec|
  spec.name          = "shopify_api-graphql-tiny"
  spec.version       = ShopifyAPI::GraphQL::Tiny::VERSION
  spec.authors       = ["Skye Shaw"]
  spec.email         = ["skye.shaw@gmail.com"]

  spec.summary       = %q{Lightweight, no-nonsense, Shopify GraphQL Admin API client with built-in pagination and retry}
  spec.homepage      = "https://github.com/ScreenStaring/shopify_api-graphql-tiny"
  spec.license       = "MIT"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.metadata = {
    "bug_tracker_uri"   => "https://github.com/ScreenStaring/shopify_api-graphql-tiny/issues",
    "changelog_uri"     => "https://github.com/ScreenStaring/shopify_api-graphql-tiny/blob/master/Changes",
    "documentation_uri" => "https://rubydoc.info/gems/shopify_api-graphql-tiny",
    "source_code_uri"   => "https://github.com/ScreenStaring/shopify_api-graphql-tiny",
  }

  spec.add_dependency "shopify_api_retry", "~> 0.2"
  spec.add_development_dependency "webmock", "~> 3.0"
  spec.add_development_dependency "bundler"
  spec.add_development_dependency "rake", ">= 12.3.3"
  spec.add_development_dependency "rspec", "~> 3.0"
end
