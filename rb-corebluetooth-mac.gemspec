# frozen_string_literal: true

require_relative "lib/corebluetooth_mac/version"

Gem::Specification.new do |spec|
  spec.name = "rb-corebluetooth-mac"
  spec.version = CoreBluetoothMac::VERSION
  spec.authors = ["bash0C7"]
  spec.email = ["ksb.4038.nullpointer+github@gmail.com"]

  spec.summary = "Native Apple CoreBluetooth (BLE central) for Ruby on macOS"
  spec.description = "rb-corebluetooth-mac drives Apple's CoreBluetooth framework " \
    "from Ruby via a Swift native extension, exposing scan / connect / discover / " \
    "read / write / notify so a macOS host can act as a BLE central. Requires " \
    "macOS 13+."
  spec.homepage = "https://github.com/bash0C7/rb-corebluetooth-mac"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/bash0C7/rb-corebluetooth-mac"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/corebluetooth_mac/extconf.rb"]

  spec.add_runtime_dependency "swift_gem", "~> 0.1"
end
