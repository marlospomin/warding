# frozen_string_literal: true

require_relative "lib/warding/version"

Gem::Specification.new do |spec|
  spec.name          = "warding"
  spec.version       = Warding::VERSION
  spec.authors       = ["Marlos Pomin"]
  spec.email         = ["marlospomin@gmail.com"]

  spec.summary       = "Warding Linux installer."
  spec.description   = "Custom Arch Linux installer designed for security assessments and pentesting."
  spec.homepage      = "https://github.com/marlospomin/warding"
  spec.license       = "MIT"

  spec.required_ruby_version = Gem::Requirement.new(">= 2.3.0")

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/marlospomin/warding"
  spec.metadata["changelog_uri"]   = "https://github.com/marlospomin/warding/releases"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end

  spec.executables   = ["warding"]
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "tty-prompt"
end
