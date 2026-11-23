# frozen_string_literal: true

if File.file?("Rakefile") && Gem::Specification.find_all_by_name("rake").any?
  exec("rake", "test", *ARGV)
elsif File.directory?("spec") && Gem::Specification.find_all_by_name("rspec-core").any?
  exec("rspec", *ARGV)
else
  files = Dir["test/**/{test_*,*_test}.rb"].sort
  abort "drvrb: no tests found; set testCommand to the project's test runner" if files.empty?
  $LOAD_PATH.unshift(File.expand_path("lib"), File.expand_path("test"))
  files.each { |file| require File.expand_path(file) }
end
