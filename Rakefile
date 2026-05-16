# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/extensiontask"
require "rake/testtask"

Rake::ExtensionTask.new("corebluetooth_mac") do |ext|
  ext.lib_dir = "lib/corebluetooth_mac"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

task test: :compile
task default: :test

namespace :clangd do
  desc "Generate ext/corebluetooth_mac/compile_flags.txt for local clangd LSP"
  task :setup do
    require "rbconfig"
    flags = [
      "-I#{RbConfig::CONFIG['rubyhdrdir']}",
      "-I#{RbConfig::CONFIG['rubyarchhdrdir']}",
      "-I.",
      "-Wall",
    ]
    path = File.expand_path("ext/corebluetooth_mac/compile_flags.txt", __dir__)
    File.write(path, flags.join("\n") + "\n")
    puts "wrote #{path}"
  end
end
