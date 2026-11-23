# frozen_string_literal: true

require "bundler"
require "json"
require "pathname"

# Use Bundler's grammar and RubyGems' platform matching, including different
# transitive dependencies on the generic Ruby and precompiled variants.
class GemPlan
  def initialize(src, member)
    @src = Pathname(src).realpath
    @member = within_workspace(@src.join(member))
    @root = @member.join("Gemfile.lock").file? ? @member : @src
    Dir.chdir(@root)
    ENV["BUNDLE_GEMFILE"] = @root.join("Gemfile").to_s
    text = File.read("Gemfile.lock")
    raise "content-addressed and ABI-specific gem archives are unsupported" if text.match?(/^(?:RUBY ABIS|CONTENT ADDRESSES)$/)
    raise "dependency override sections are unsupported" if text.match?(/^OVERRIDES$/)
    @lock = Bundler::LockfileParser.new(text)
    @specs = @lock.specs.group_by(&:name)
    @gems = {}
    @visiting = []
  end

  def within_workspace(path)
    full = path.realpath
    rel = full.relative_path_from(@src)
    raise "local path outside the selected workspace: #{path}" if rel.each_filename.first == ".."
    full
  end

  def checksum(spec)
    spec.source.checksum_store.to_lock(spec)[/(?: |,)sha256=([0-9a-f]{64})(?:,|$)/, 1]
  end

  def registry(spec, remote)
    sha = checksum(spec) or raise "#{spec.full_name} has no SHA-256 in Gemfile.lock; run bundle lock --add-checksums"
    uri = Gem::URI.parse(remote.to_s)
    unless uri.scheme == "https" && uri.host && !uri.userinfo && !uri.query && !uri.fragment
      raise "expected one public HTTPS registry for #{spec.full_name}"
    end
    { "url" => "#{uri.to_s.sub(%r{/+$}, "")}/gems/#{spec.full_name}.gem", "sha256" => sha }
  end

  def local_gem(spec)
    path = within_workspace(@root.join(spec.source.options.fetch("path")))
    files = Dir.glob(spec.source.options.fetch("glob", "{,*,*/*}.gemspec"), base: path)
    file = files.find do |relative|
      gemspec = Bundler.load_gemspec(within_workspace(path.join(relative)).to_s)
      gemspec && gemspec.name == spec.name && gemspec.version == spec.version
    end
    raise "no gemspec matching #{spec.full_name} under #{path}" unless file
    gemspec = within_workspace(path.join(file))
    source = { "path" => gemspec.dirname.relative_path_from(@src).to_s, "gemspec" => gemspec.basename.to_s }
    if Bundler.load_gemspec(gemspec.to_s).extensions.any?
      source["extensions"] = File.join("extensions", Gem::Platform.local.to_s, Gem.extension_api_version, spec.full_name)
    end
    source
  end

  def add(dep)
    name = dep.name
    if @visiting.include?(name)
      raise "cyclic gem dependencies: #{(@visiting + [name]).join(" -> ")}"
    end
    if @gems.key?(name)
      raise "incompatible locked requirements for #{name}" unless dep.match?(name, @gems[name].fetch("version"))
      return
    end
    if name == "bundler" && !@specs.key?(name)
      raise "incompatible Bundler dependency #{dep}" unless dep.match?(name, Bundler::VERSION)
      return
    end
    candidates = Array(@specs[name]).select { |s| dep.match?(s.name, s.version) }
    selected = Bundler::MatchPlatform.select_best_platform_match(candidates, Gem::Platform.local,
      force_ruby: dep.respond_to?(:force_ruby_platform) && dep.force_ruby_platform)
    raise "expected one locked variant of #{dep} for #{Gem::Platform.local}, found #{selected.map(&:full_name)}" unless selected.size == 1
    spec = selected.first
    raise "invalid gem name #{name.inspect}" unless name.match?(/\A[a-zA-Z0-9_.-]+\z/) && ![".", ".."].include?(name)
    source = case spec.source
    when Bundler::Source::Git
      raise "git-sourced gem #{name} is unsupported; use a checksummed gem or a workspace path"
    when Bundler::Source::Path
      local_gem(spec)
    when Bundler::Source::Rubygems
      remotes = spec.source.remotes
      raise "ambiguous registry for #{name}" unless remotes.size == 1
      registry(spec, remotes.first)
    when Bundler::Source::Metadata
      registry(spec, "https://rubygems.org/")
    else
      raise "unsupported source for #{name}"
    end
    @visiting << name
    deps = spec.dependencies.reject { |d| d.type == :development }
    deps.each { |d| add(d) }
    @visiting.pop
    @gems[name] = source.merge("full" => spec.full_name, "version" => spec.version.to_s,
      "deps" => deps.map(&:name).select { |d| @gems.key?(d) }.uniq.sort)
  end

  def generate
    definition = Bundler.definition
    definition.ensure_equivalent_gemfile_and_lockfile
    roots = definition.dependencies.select(&:should_include?)
    if @lock.bundler_version
      tool = Bundler::LazySpecification.new("bundler", @lock.bundler_version, Gem::Platform::RUBY, @lock.metadata_source)
      if checksum(tool)
        @specs["bundler"] ||= [tool]
        roots = [Gem::Dependency.new("bundler", "= #{@lock.bundler_version}")] + roots
      end
    end
    roots.each { |d| add(d) }
    { "root" => @root.relative_path_from(@src).to_s, "member" => @member.relative_path_from(@src).to_s, "gems" => @gems.sort.to_h }
  end
end

begin
  puts JSON.generate(GemPlan.new(*ARGV).generate)
rescue StandardError => e
  abort "drvrb: #{e.message}"
end
