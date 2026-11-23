Gem::Specification.new do |s|
  s.name = "greeting"
  s.version = "1.0.0"
  s.summary = "Shared example greeting"
  s.authors = ["drvlang"]
  s.files = ["lib/greeting.rb"]
  s.files += Dir["ext/greeting/*"]
  s.extensions = ["ext/greeting/extconf.rb"]
  s.add_runtime_dependency "base64", "= 0.3.0"
end
