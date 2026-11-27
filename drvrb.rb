# frozen_string_literal: true

require "fileutils"
require "json"

# --- Nix store paths, ATerm formatting, and protocol-1.21 daemon client ---

module NixStore
  NIX_B32 = "0123456789abcdfghijklmnpqrsvwxyz"
  CLIENT_MAGIC = 0x6e697863
  SERVER_MAGIC = 0x6478696f
  PROTOCOL_1_21 = (1 << 8) | 21
  STDERR_NEXT = 0x6f6c6d67
  STDERR_LAST = 0x616c7473
  STDERR_ERROR = 0x63787470
  WOP_ADD_TEXT_TO_STORE = 8
  WOP_QUERY_VALID_PATHS = 31

  module_function

  def store_dir
    d = ENV["NIX_STORE"] || "/nix/store"
    d.start_with?("/") ? d.sub(%r{/+\z}, "").then { |s| s.empty? ? "/" : s } : "/nix/store"
  end

  def nix_base32(data)
    bytes = data.bytes
    out_len = (bytes.length * 8 - 1) / 5 + 1
    out = String.new(capacity: out_len)
    out_len.times do |n|
      b = (out_len - 1 - n) * 5
      i = b / 8
      j = b % 8
      c = bytes[i] >> j
      c |= bytes[i + 1] << (8 - j) if j > 0 && i + 1 < bytes.length
      out << NIX_B32[c & 0x1f]
    end
    out
  end

  def compress_hash(digest_bytes, size)
    out = Array.new(size, 0)
    digest_bytes.bytes.each_with_index { |b, i| out[i % size] ^= b }
    out.pack("C*")
  end

  def make_store_path(sdir, type, sha256_hex, name)
    require "digest"
    fp = "#{type}:sha256:#{sha256_hex}:#{sdir}:#{name}"
    h = nix_base32(compress_hash(Digest::SHA256.digest(fp), 20))
    "#{sdir}/#{h}-#{name}"
  end

  def make_text_path(sdir, name, text, refs)
    require "digest"
    digest = Digest::SHA256.hexdigest(text)
    typ = "text" + refs.uniq.sort.map { |r| ":#{r}" }.join
    make_store_path(sdir, typ, digest, name)
  end

  def make_fixed_output_path(sdir, name, sha256_hex)
    require "digest"
    inner = Digest::SHA256.hexdigest("fixed:out:sha256:#{sha256_hex}:")
    make_store_path(sdir, "output:out", inner, name)
  end

  def hash_placeholder(output_name)
    require "digest"
    "/" + nix_base32(Digest::SHA256.digest("nix-output:#{output_name}"))
  end

  def downstream_placeholder(drv_path, output_name)
    require "digest"
    base = File.basename(drv_path)
    hash_part = base[0, 32]
    drv_name = base[33..].delete_suffix(".drv")
    out_name = output_name == "out" ? drv_name : "#{drv_name}-#{output_name}"
    "/" + nix_base32(Digest::SHA256.digest("nix-upstream-output:#{hash_part}:#{out_name}"))
  end

  def aterm_str(s)
    escaped = s.to_s
      .gsub("\\", "\\\\\\\\")
      .gsub('"', '\\"')
      .gsub("\n", "\\n")
      .gsub("\r", "\\r")
      .gsub("\t", "\\t")
    "\"#{escaped}\""
  end

  def format_derivation(outputs:, input_drvs:, input_srcs:, platform:, builder:, args:, env:)
    outs = outputs.sort_by { |o| o[0] }.map do |n, p, a, h|
      "(#{aterm_str(n)},#{aterm_str(p)},#{aterm_str(a)},#{aterm_str(h)})"
    end.join(",")
    idrvs = input_drvs.sort_by { |k, _| k }.map do |d, os|
      "(#{aterm_str(d)},[#{os.uniq.sort.map { |o| aterm_str(o) }.join(",")}])"
    end.join(",")
    isrcs = input_srcs.uniq.sort.map { |s| aterm_str(s) }.join(",")
    a_str = args.map { |a| aterm_str(a) }.join(",")
    e_str = env.sort_by { |k, _| k }.map { |k, v| "(#{aterm_str(k)},#{aterm_str(v)})" }.join(",")
    "Derive([#{outs}],[#{idrvs}],[#{isrcs}],#{aterm_str(platform)},#{aterm_str(builder)},[#{a_str}],[#{e_str}])".b
  end

  def make_fetchurl_drv(sdir, name, url, sha256_hex)
    out_path = make_fixed_output_path(sdir, name, sha256_hex)
    env = {
      "builder" => "builtin:fetchurl",
      "executable" => "",
      "impureEnvVars" => "http_proxy https_proxy ftp_proxy all_proxy no_proxy",
      "name" => name,
      "out" => out_path,
      "outputHash" => sha256_hex,
      "outputHashAlgo" => "sha256",
      "outputHashMode" => "flat",
      "preferLocalBuild" => "1",
      "system" => "builtin",
      "unpack" => "",
      "url" => url,
      "urls" => url,
    }
    aterm = format_derivation(
      outputs: [["out", out_path, "sha256", sha256_hex]],
      input_drvs: {},
      input_srcs: [],
      platform: "builtin",
      builder: "builtin:fetchurl",
      args: [],
      env: env
    )
    drv_name = "#{name}.drv"
    drv_path = make_text_path(sdir, drv_name, aterm, [])
    { drv_path: drv_path, out_path: out_path, name: drv_name, aterm: aterm, refs: [] }
  end

  def make_ca_drv(sdir:, name:, system:, builder:, args:, input_drvs:, input_srcs:, env:, mode: "recursive")
    ph = hash_placeholder("out")
    full_env = env.merge(
      "builder" => builder,
      "name" => name,
      "out" => ph,
      "outputHashAlgo" => "sha256",
      "outputHashMode" => mode,
      "system" => system
    )
    algo = mode == "text" ? "text:sha256" : "r:sha256"
    aterm = format_derivation(
      outputs: [["out", "", algo, ""]],
      input_drvs: input_drvs,
      input_srcs: input_srcs,
      platform: system,
      builder: builder,
      args: args,
      env: full_env
    )
    refs = (input_drvs.keys + input_srcs).uniq.sort
    drv_name = "#{name}.drv"
    drv_path = make_text_path(sdir, drv_name, aterm, refs)
    { drv_path: drv_path, name: drv_name, aterm: aterm, refs: refs }
  end

  class DaemonClient
    def initialize(remote)
      require "socket"
      sock_path =
        if remote.start_with?("unix://")
          remote.delete_prefix("unix://").split("?", 2).first
        elsif remote == "daemon"
          "/nix/var/nix/daemon-socket/socket"
        else
          raise "unsupported NIX_REMOTE=#{remote.inspect}"
        end
      @sock = UNIXSocket.new(sock_path)
      @buf = "".b
      handshake
    end

    def close
      @sock.close
    end

    def query_valid_paths(paths)
      return [] if paths.empty?
      send_u64(WOP_QUERY_VALID_PATHS)
      send_str_set(paths)
      flush
      drain_stderr
      recv_str_set
    end

    def add_text_to_store(name, text, refs)
      send_u64(WOP_ADD_TEXT_TO_STORE)
      send_str(name)
      send_bytes(text)
      send_str_set(refs)
      flush
      drain_stderr
      recv_str
    end

    def ensure_registered(records)
      return if records.empty?
      unique = {}
      ordered = []
      records.each do |rec|
        next if unique.key?(rec[:drv_path])
        unique[rec[:drv_path]] = rec
        ordered << rec
      end
      valid = query_valid_paths(ordered.map { |r| r[:drv_path] }).each_with_object({}) { |p, h| h[p] = true }
      ordered.each do |rec|
        next if valid[rec[:drv_path]]
        actual = add_text_to_store(rec[:name], rec[:aterm], rec[:refs])
        if actual != rec[:drv_path]
          raise "derivation path mismatch for #{rec[:name]}: predicted #{rec[:drv_path]}, daemon returned #{actual}"
        end
      end
    end

    private

    def send_u64(v)
      @buf << [v].pack("Q<")
    end

    def send_bytes(b)
      bin = b.b
      send_u64(bin.bytesize)
      @buf << bin
      pad = (8 - (bin.bytesize % 8)) % 8
      @buf << ("\0".b * pad) if pad > 0
    end

    def send_str(s)
      send_bytes(s.to_s)
    end

    def send_str_set(items)
      send_u64(items.length)
      items.each { |s| send_str(s) }
    end

    def flush
      return if @buf.empty?
      @sock.write(@buf)
      @buf.clear
    end

    def recv_exact(n)
      data = "".b
      while data.bytesize < n
        chunk = @sock.read(n - data.bytesize)
        raise "unexpected EOF from nix daemon" if chunk.nil? || chunk.empty?
        data << chunk
      end
      data
    end

    def recv_u64
      recv_exact(8).unpack1("Q<")
    end

    def recv_bytes
      n = recv_u64
      data = recv_exact(n)
      pad = (8 - (n % 8)) % 8
      recv_exact(pad) if pad > 0
      data
    end

    def recv_str
      recv_bytes.force_encoding(Encoding::UTF_8)
    end

    def recv_str_set
      Array.new(recv_u64) { recv_str }
    end

    def drain_stderr
      loop do
        code = recv_u64
        case code
        when STDERR_LAST
          return
        when STDERR_NEXT
          recv_bytes
        when STDERR_ERROR
          msg = recv_str
          recv_u64
          raise "nix daemon error: #{msg}"
        else
          raise format("unexpected nix daemon stderr code 0x%x", code)
        end
      end
    end

    def handshake
      send_u64(CLIENT_MAGIC)
      flush
      magic = recv_u64
      raise format("unexpected nix daemon magic 0x%x", magic) unless magic == SERVER_MAGIC
      recv_u64 # server version
      send_u64(PROTOCOL_1_21)
      send_u64(0) # cpuAffinity
      send_u64(0) # reserveSpace
      flush
      drain_stderr
    end
  end
end

# --- Bundler lockfile planner ---

class GemPlan
  def initialize(src, member)
    @src = Pathname(src).realpath
    @member = within_workspace(@src.join(member))
    @root = @member.join("Gemfile.lock").file? ? @member : @src
    Dir.chdir(@root)
    ENV["HOME"] = ENV["TMPDIR"] || "/tmp"
    ENV["BUNDLE_IGNORE_CONFIG"] = "1"
    ENV["BUNDLE_FROZEN"] = "true"
    ENV["BUNDLE_VERSION"] = "system"
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
    { "url" => "#{uri.to_s.sub(%r{/+\z}, "")}/gems/#{spec.full_name}.gem", "sha256" => sha }
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
    selected = Bundler::MatchPlatform.select_best_platform_match(
      candidates,
      Gem::Platform.local,
      force_ruby: dep.respond_to?(:force_ruby_platform) && dep.force_ruby_platform
    )
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
    @gems[name] = source.merge(
      "full" => spec.full_name,
      "version" => spec.version.to_s,
      "deps" => deps.map(&:name).select { |d| @gems.key?(d) }.uniq.sort
    )
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
    {
      "root" => @root.relative_path_from(@src).to_s,
      "member" => @member.relative_path_from(@src).to_s,
      "gems" => @gems.sort.to_h,
    }
  end
end

# --- Subcommands ---

module DrvRb
  module_function

  def stage1
    require "bundler"
    require "pathname"
    sdir = NixStore.store_dir
    src = ENV.fetch("SRC")
    member_path = ENV.fetch("MEMBER_PATH")
    ruby = ENV.fetch("RUBY")
    script = ENV.fetch("SCRIPT")
    system = ENV.fetch("SYSTEM")
    gem_inputs = JSON.parse(ENV.fetch("GEM_INPUTS_JSON"))
    gem_flags = JSON.parse(ENV.fetch("GEM_FLAGS_JSON"))

    plan = GemPlan.new(src, member_path).generate
    records = []
    stage2_input_drvs = {}
    stage2_input_srcs = [
      ruby,
      script,
      ENV.fetch("STDENV_DRV"),
      ENV.fetch("PKG_CONFIG_DRV"),
      ENV.fetch("BASH_DRV"),
    ]
    has_local = false

    gems_for_stage2 = {}
    plan["gems"].each do |name, spec|
      entry = spec.dup
      if spec.key?("path")
        has_local = true
        if spec["path"] == "."
          entry["src_path"] = src
          stage2_input_srcs << src
        else
          slice_rec = NixStore.make_ca_drv(
            sdir: sdir,
            name: "source-#{name}",
            system: system,
            builder: "#{ruby}/bin/ruby",
            args: ["--disable-gems", script, "slice", src, spec["path"]],
            input_drvs: {},
            input_srcs: [ruby, script, src],
            env: {}
          )
          records << slice_rec
          entry["src_drv"] = slice_rec[:drv_path]
          stage2_input_srcs << slice_rec[:drv_path]
        end
      else
        fetch_rec = NixStore.make_fetchurl_drv(sdir, "#{spec["full"]}.gem", spec["url"], spec["sha256"])
        records << fetch_rec
        entry["archive"] = fetch_rec[:out_path]
        entry["fetch_drv"] = fetch_rec[:drv_path]
        stage2_input_drvs[fetch_rec[:drv_path]] = ["out"]
        stage2_input_srcs << fetch_rec[:drv_path]
      end
      gems_for_stage2[name] = entry
    end

    filtered_inputs = {}
    filtered_flags = {}
    plan["gems"].each_key do |name|
      if gem_inputs.key?(name) && !gem_inputs[name].empty?
        filtered_inputs[name] = gem_inputs[name]
        gem_inputs[name].each { |inp| stage2_input_srcs << inp["drv"] }
      end
      if gem_flags.key?(name) && !gem_flags[name].empty?
        filtered_flags[name] = gem_flags[name]
      end
    end

    stage2_env = {
      "PLAN_JSON" => JSON.generate({
        "root" => plan["root"],
        "member" => plan["member"],
        "gems" => gems_for_stage2,
      }),
      "GEM_INPUTS_JSON" => JSON.generate(filtered_inputs),
      "GEM_FLAGS_JSON" => JSON.generate(filtered_flags),
      "RUBY" => ruby,
      "SCRIPT" => script,
      "SYSTEM" => system,
      "STDENV_DRV" => ENV.fetch("STDENV_DRV"),
      "STDENV_OUT" => ENV.fetch("STDENV_OUT"),
      "PKG_CONFIG_DRV" => ENV.fetch("PKG_CONFIG_DRV"),
      "PKG_CONFIG_OUT" => ENV.fetch("PKG_CONFIG_OUT"),
      "BASH_DRV" => ENV.fetch("BASH_DRV"),
      "BASH_OUT" => ENV.fetch("BASH_OUT"),
      "requiredSystemFeatures" => "recursive-nix",
    }
    if has_local
      stage2_input_srcs << ENV.fetch("GIT_DRV")
      stage2_env["GIT_DRV"] = ENV.fetch("GIT_DRV")
      stage2_env["GIT_OUT"] = ENV.fetch("GIT_OUT")
    end

    stage2_rec = NixStore.make_ca_drv(
      sdir: sdir,
      name: "drvrb-gems.drv",
      system: system,
      builder: "#{ruby}/bin/ruby",
      args: [script, "stage2"],
      input_drvs: stage2_input_drvs,
      input_srcs: stage2_input_srcs,
      env: stage2_env,
      mode: "text"
    )

    if !records.empty?
      client = NixStore::DaemonClient.new(ENV.fetch("NIX_REMOTE"))
      begin
        client.ensure_registered(records)
      ensure
        client.close
      end
    end

    File.binwrite(ENV.fetch("out"), stage2_rec[:aterm])
  end

  def topo_order(gems)
    visited = {}
    order = []
    visit = lambda do |name|
      return if visited[name]
      visited[name] = true
      gems[name]["deps"].each { |d| visit.call(d) }
      order << name
    end
    gems.keys.sort.each { |n| visit.call(n) }
    order
  end

  def stage2
    require "rubygems/package"
    sdir = NixStore.store_dir
    plan = JSON.parse(ENV.fetch("PLAN_JSON"))
    gem_inputs = JSON.parse(ENV.fetch("GEM_INPUTS_JSON"))
    gem_flags = JSON.parse(ENV.fetch("GEM_FLAGS_JSON"))
    ruby = ENV.fetch("RUBY")
    script = ENV.fetch("SCRIPT")
    system = ENV.fetch("SYSTEM")

    gems = plan["gems"]
    order = topo_order(gems)
    gem_drvs = {}
    closure_by_name = {}
    records = []

    order.each do |name|
      spec = gems[name]
      deps = spec["deps"]
      closure = deps.flat_map { |d| [d] + closure_by_name[d] }.uniq.sort
      closure_by_name[name] = closure

      local = spec.key?("path")
      if local
        needs_native = true
      else
        archive = spec["archive"]
        pkg_spec = Gem::Package.new(archive).spec
        if pkg_spec.full_name != spec["full"]
          raise "gem identity: expected #{spec["full"]}, got #{pkg_spec.full_name}"
        end
        needs_native = !pkg_spec.extensions.empty?
      end

      input_drvs = {}
      input_srcs = [ruby, script]
      closure.each { |d| input_drvs[gem_drvs[d]] = ["out"] }

      env = {
        "GEM_NAME" => name,
        "GEM_FULL" => spec["full"],
        "GEM_VERSION" => spec["version"],
        "GEM_PATH_LIST" => closure.map { |d| NixStore.downstream_placeholder(gem_drvs[d], "out") }.join(":"),
        "GEM_FLAGS_JSON" => JSON.generate(gem_flags[name] || []),
        "NEEDS_NATIVE" => needs_native ? "1" : "0",
        "RUBY" => ruby,
      }

      if local
        env["GEM_SPEC"] = spec["gemspec"]
        if spec.key?("src_drv")
          input_drvs[spec["src_drv"]] = ["out"]
          env["GEM_LOCAL_SRC"] = NixStore.downstream_placeholder(spec["src_drv"], "out")
        else
          input_srcs << spec["src_path"]
          env["GEM_LOCAL_SRC"] = spec["src_path"]
        end
      else
        input_drvs[spec["fetch_drv"]] = ["out"]
        env["GEM_ARCHIVE"] = spec["archive"]
      end

      extra = gem_inputs[name] || []
      extra.each { |inp| input_drvs[inp["drv"]] = ["out"] }
      env["GEM_INPUTS_OUTS"] = extra.map { |inp| inp["out"] }.join(" ") unless extra.empty?

      if needs_native
        input_drvs[ENV.fetch("STDENV_DRV")] = ["out"]
        input_drvs[ENV.fetch("PKG_CONFIG_DRV")] = ["out"]
        input_drvs[ENV.fetch("BASH_DRV")] = ["out"]
        env["STDENV_OUT"] = ENV.fetch("STDENV_OUT")
        env["PKG_CONFIG_OUT"] = ENV.fetch("PKG_CONFIG_OUT")
        env["BASH_OUT"] = ENV.fetch("BASH_OUT")
        if local
          input_drvs[ENV.fetch("GIT_DRV")] = ["out"]
          env["GIT_OUT"] = ENV.fetch("GIT_OUT")
        end
      end

      rec = NixStore.make_ca_drv(
        sdir: sdir,
        name: "drvrb-#{name}-#{spec["version"]}",
        system: system,
        builder: "#{ruby}/bin/ruby",
        args: [script, "install-gem"],
        input_drvs: input_drvs,
        input_srcs: input_srcs,
        env: env
      )
      gem_drvs[name] = rec[:drv_path]
      records << rec
    end

    if !records.empty?
      client = NixStore::DaemonClient.new(ENV.fetch("NIX_REMOTE"))
      begin
        client.ensure_registered(records)
      ensure
        client.close
      end
    end

    assemble_input_drvs = {}
    gems_map = {}
    extensions_map = {}
    gems.keys.sort.each do |name|
      drv = gem_drvs[name]
      assemble_input_drvs[drv] = ["out"]
      ph = NixStore.downstream_placeholder(drv, "out")
      gems_map[name] = ph
      extensions_map[name] = gems[name]["extensions"] if gems[name].key?("extensions")
    end

    bundler_version = gems.key?("bundler") ? gems["bundler"]["version"] : "system"
    bundle = gems.key?("bundler") ? "#{gems_map["bundler"]}/bin/bundle" : "#{ruby}/bin/bundle"
    root_suffix = plan["root"] == "." ? "" : "/#{plan["root"]}"
    member_suffix = plan["member"] == "." ? "" : "/#{plan["member"]}"

    assemble_rec = NixStore.make_ca_drv(
      sdir: sdir,
      name: "drvrb-gems",
      system: system,
      builder: "#{ruby}/bin/ruby",
      args: ["--disable-gems", script, "assemble"],
      input_drvs: assemble_input_drvs,
      input_srcs: [ruby, script],
      env: {
        "GEMS_MAP_JSON" => JSON.generate(gems_map),
        "META_JSON" => JSON.generate({
          "bundle" => bundle,
          "bundler_version" => bundler_version,
          "extensions_map" => extensions_map,
          "root_suffix" => root_suffix,
          "member_suffix" => member_suffix,
          "ruby" => ruby,
        }),
      }
    )

    File.binwrite(ENV.fetch("out"), assemble_rec[:aterm])
  end

  def slice(src, rel)
    out = ENV.fetch("out")
    source_dir = File.join(src, rel)
    FileUtils.cp_r(source_dir, out, preserve: false)
  end

  def patch_ruby_shebangs(bin_dir, ruby_bin)
    return unless Dir.exist?(bin_dir)
    Dir.children(bin_dir).sort.each do |entry|
      path = File.join(bin_dir, entry)
      next unless File.file?(path) && !File.symlink?(path)
      data = File.binread(path)
      next unless data.start_with?("#!")
      nl = data.index("\n")
      first = nl ? data[0...nl] : data
      if first =~ /\A#!\s*(?:\/usr\/bin\/env\s+)?(?:(?:\S+\/)?ruby)(?:\s+(.*))?\z/
        rest = Regexp.last_match(1)
        new_shebang = rest && !rest.empty? ? "#!#{ruby_bin} #{rest}" : "#!#{ruby_bin}"
        new_data = nl ? "#{new_shebang}#{data[nl..]}" : new_shebang
        File.binwrite(path, new_data)
      end
    end
  end

  def install_gem
    require "rubygems/installer"
    require "shellwords"
    out = ENV.fetch("out")
    ruby = ENV.fetch("RUBY")
    ruby_bin = "#{ruby}/bin/ruby"
    full = ENV.fetch("GEM_FULL")
    gem_path_list = ENV.fetch("GEM_PATH_LIST", "")
    flags = JSON.parse(ENV.fetch("GEM_FLAGS_JSON", "[]"))
    needs_native = ENV.fetch("NEEDS_NATIVE") == "1"

    ENV["HOME"] = ENV["TMPDIR"] || "/tmp"
    ENV["SOURCE_DATE_EPOCH"] = "1"
    ENV["GEM_HOME"] = out
    ENV["GEM_PATH"] = gem_path_list

    if !needs_native
      archive = ENV.fetch("GEM_ARCHIVE")
      FileUtils.mkdir_p(out)
      installer = Gem::Installer.at(
        archive,
        install_dir: out,
        ignore_dependencies: true,
        document: [],
        env_shebang: true,
        wrappers: true,
        force: true,
        build_args: flags
      )
      installer.install
      cache_dir = File.join(out, "cache")
      FileUtils.mkdir_p(cache_dir)
      cache_gem = File.join(cache_dir, "#{full}.gem")
      FileUtils.cp(archive, cache_gem) unless File.exist?(cache_gem)
      patch_ruby_shebangs(File.join(out, "bin"), ruby_bin)
      return
    end

    stdenv = ENV.fetch("STDENV_OUT")
    pkg_config = ENV.fetch("PKG_CONFIG_OUT")
    bash = ENV.fetch("BASH_OUT")
    git_out = ENV["GIT_OUT"]
    local_src = ENV["GEM_LOCAL_SRC"]
    gemspec = ENV["GEM_SPEC"]
    archive = ENV["GEM_ARCHIVE"]
    gem_inputs_outs = ENV.fetch("GEM_INPUTS_OUTS", "")

    native_inputs = [ruby, pkg_config]
    native_inputs << git_out if git_out && !git_out.empty?

    build_steps = +""
    build_steps << "export stdenv=#{Shellwords.escape(stdenv)}\n"
    build_steps << "export NIX_BUILD_TOP=\"$TMPDIR\"\n"
    build_steps << "export strictDeps=1\n"
    build_steps << "export nativeBuildInputs=#{Shellwords.escape(native_inputs.join(" "))}\n"
    build_steps << "export buildInputs=#{Shellwords.escape(gem_inputs_outs)}\n"
    build_steps << "source #{Shellwords.escape(stdenv)}/setup\n"
    build_steps << "export HOME=\"$TMPDIR\" GEM_HOME=\"$out\" GEM_PATH=#{Shellwords.escape(gem_path_list)} SOURCE_DATE_EPOCH=1\n"
    if local_src
      build_steps << "cp -R #{Shellwords.escape(local_src)} \"$TMPDIR/source\"\n"
      build_steps << "chmod -R u+w \"$TMPDIR/source\"\n"
      build_steps << "cd \"$TMPDIR/source\"\n"
      build_steps << "git init -q\n"
      build_steps << "git add --all\n"
      build_steps << "gem build #{Shellwords.escape(gemspec)} --output \"$TMPDIR/package.gem\"\n"
      build_steps << "archive=\"$TMPDIR/package.gem\"\n"
      build_steps << "#{Shellwords.escape(ruby_bin)} -rrubygems/package -e 's = Gem::Package.new(ARGV[0]).spec; abort \"gem identity: expected \#{ARGV[1]}, got \#{s.full_name}\" unless s.full_name == ARGV[1]' \"$archive\" #{Shellwords.escape(full)}\n"
    else
      build_steps << "archive=#{Shellwords.escape(archive)}\n"
    end
    flag_args = flags.empty? ? "" : " -- #{flags.map { |f| Shellwords.escape(f) }.join(" ")}"
    build_steps << "gem install --norc --env-shebang --local --ignore-dependencies --no-document --install-dir \"$out\" \"$archive\"#{flag_args}\n"
    build_steps << "if [[ -d \"$out/bin\" ]]; then patchShebangs --build \"$out/bin\"; fi\n"

    ok = system("#{bash}/bin/bash", "-e", "-c", build_steps)
    raise "gem install failed for #{full}" unless ok
  end

  def merge_tree(src, dst)
    return unless File.exist?(src) || File.symlink?(src)
    if File.directory?(src) && !File.symlink?(src)
      FileUtils.mkdir_p(dst)
      Dir.children(src).sort.each do |child|
        s = File.join(src, child)
        d = File.join(dst, child)
        if !File.exist?(d) && !File.symlink?(d)
          File.symlink(s, d)
        elsif File.symlink?(d)
          existing = File.readlink(d)
          if File.directory?(existing) && File.directory?(s) && !File.symlink?(s)
            File.delete(d)
            FileUtils.mkdir_p(d)
            merge_tree(existing, d)
            merge_tree(s, d)
          end
        elsif File.directory?(d) && File.directory?(s) && !File.symlink?(s)
          merge_tree(s, d)
        end
      end
    elsif !File.exist?(dst) && !File.symlink?(dst)
      File.symlink(src, dst)
    end
  end

  def assemble
    out = ENV.fetch("out")
    gems_map = JSON.parse(ENV.fetch("GEMS_MAP_JSON"))
    meta = JSON.parse(ENV.fetch("META_JSON"))

    dirs = %w[gems specifications extensions cache plugins build_info bin]
    FileUtils.mkdir_p(File.join(out, "nix-support"))

    gems_map.keys.sort.each do |name|
      gem_dir = gems_map[name]
      dirs.each do |dir|
        src = File.join(gem_dir, dir)
        merge_tree(src, File.join(out, dir)) if Dir.exist?(src)
      end
    end

    extensions = meta["extensions_map"].keys.sort.map { |name| "#{gems_map[name]}/#{meta["extensions_map"][name]}" }.join(":")

    File.write(File.join(out, "nix-support", "gem-paths.json"), JSON.generate(gems_map))
    File.write(File.join(out, "nix-support", "env.json"), JSON.generate({
      "bundle" => meta["bundle"],
      "bundler_version" => meta["bundler_version"],
      "extensions" => extensions,
      "root_suffix" => meta["root_suffix"],
      "member_suffix" => meta["member_suffix"],
      "ruby" => meta["ruby"],
    }))
  end

  def write_wrapper(dest, ruby_bin, env_set:, path_prefix:, rubylib_prefix:, exec_cmd:)
    lines = [
      "#!#{ruby_bin} --disable-gems",
      "# frozen_string_literal: true",
    ]
    env_set.each do |k, v|
      lines << "ENV[#{k.inspect}] = #{v.inspect}"
    end
    lines << "ENV[\"PATH\"] = ENV[\"PATH\"] && !ENV[\"PATH\"].empty? ? \"#{path_prefix}:\#{ENV[\"PATH\"]}\" : #{path_prefix.inspect}"
    if rubylib_prefix && !rubylib_prefix.empty?
      lines << "ENV[\"RUBYLIB\"] = ENV[\"RUBYLIB\"] && !ENV[\"RUBYLIB\"].empty? ? \"#{rubylib_prefix}:\#{ENV[\"RUBYLIB\"]}\" : #{rubylib_prefix.inspect}"
    end
    args_str = exec_cmd.map(&:inspect).join(", ")
    lines << "exec(#{args_str}, *ARGV)"
    File.write(dest, lines.join("\n") + "\n")
    File.chmod(0o755, dest)
  end

  def package
    out = ENV.fetch("out")
    src = ENV.fetch("SRC")
    env_dir = ENV.fetch("ENV_DIR")
    meta = JSON.parse(File.read(File.join(env_dir, "nix-support", "env.json")))
    ruby = meta["ruby"]
    ruby_bin = "#{ruby}/bin/ruby"
    bundle = meta["bundle"]
    extensions = meta["extensions"]
    root_suffix = meta["root_suffix"]
    member_suffix = meta["member_suffix"]

    FileUtils.mkdir_p(File.join(out, "bin"))
    FileUtils.mkdir_p(File.join(out, "nix-support"))

    %w[gems specifications extensions cache plugins build_info].each do |dir|
      target = File.join(env_dir, dir)
      dest = File.join(out, dir)
      if File.exist?(target) || File.symlink?(target)
        File.symlink(target, dest)
      else
        FileUtils.mkdir_p(dest)
      end
    end
    File.symlink(File.join(env_dir, "nix-support", "gem-paths.json"), File.join(out, "nix-support", "gem-paths.json"))

    env_set = {
      "GEM_HOME" => env_dir,
      "GEM_PATH" => env_dir,
      "BUNDLE_GEMFILE" => "#{src}#{root_suffix}/Gemfile",
      "BUNDLE_IGNORE_CONFIG" => "1",
      "BUNDLE_FROZEN" => "true",
      "BUNDLE_VERSION" => meta["bundler_version"],
    }
    path_prefix = "#{ruby}/bin:#{env_dir}/bin"

    write_wrapper(File.join(out, "bin", "ruby"), ruby_bin,
      env_set: env_set, path_prefix: path_prefix, rubylib_prefix: extensions,
      exec_cmd: [ruby_bin, "-rbundler/setup"])
    write_wrapper(File.join(out, "bin", "gem"), ruby_bin,
      env_set: env_set, path_prefix: path_prefix, rubylib_prefix: extensions,
      exec_cmd: ["#{ruby}/bin/gem"])
    write_wrapper(File.join(out, "bin", "bundle"), ruby_bin,
      env_set: env_set, path_prefix: path_prefix, rubylib_prefix: extensions,
      exec_cmd: [bundle])

    gem_bin_dir = File.join(env_dir, "bin")
    if Dir.exist?(gem_bin_dir)
      Dir.children(gem_bin_dir).sort.each do |name|
        dest = File.join(out, "bin", name)
        next if File.exist?(dest) || File.symlink?(dest)
        write_wrapper(dest, ruby_bin,
          env_set: env_set, path_prefix: path_prefix, rubylib_prefix: extensions,
          exec_cmd: [bundle, "exec", File.join(gem_bin_dir, name)])
      end
    end

    programs = []
    %w[exe bin].each do |sub|
      dir = File.join("#{src}#{member_suffix}", sub)
      next unless Dir.exist?(dir)
      Dir.children(dir).sort.each do |name|
        entry = File.join(dir, name)
        next unless File.file?(entry) && File.executable?(entry)
        next if %w[bundle ruby gem].include?(name)
        dest = File.join(out, "bin", name)
        File.delete(dest) if File.exist?(dest) || File.symlink?(dest)
        first_line = File.open(entry, "rb") { |f| f.gets } || ""
        exec_cmd =
          if first_line.match?(/\A#!\s*(?:\/usr\/bin\/env\s+)?(?:(?:\S+\/)?ruby)\s*\r?\n?\z/)
            [ruby_bin, "-rbundler/setup", entry]
          else
            [bundle, "exec", entry]
          end
        write_wrapper(dest, ruby_bin,
          env_set: env_set, path_prefix: path_prefix, rubylib_prefix: extensions,
          exec_cmd: exec_cmd)
        programs << name
      end
    end

    if programs.length == 1
      File.symlink("../bin/#{programs[0]}", File.join(out, "nix-support", "drvrb-run"))
    else
      File.symlink("../bin/ruby", File.join(out, "nix-support", "drvrb-run"))
    end

    check_env = env_set.merge("PATH" => ENV["PATH"] && !ENV["PATH"].empty? ? "#{path_prefix}:#{ENV["PATH"]}" : path_prefix)
    check_env["RUBYLIB"] = ENV["RUBYLIB"] && !ENV["RUBYLIB"].empty? ? "#{extensions}:#{ENV["RUBYLIB"]}" : extensions unless extensions.empty?
    ok = system(check_env, bundle, "check")
    raise "bundle check failed" unless ok
  end

  def run_tests
    out = ENV.fetch("out")
    src = ENV.fetch("SRC")
    env_dir = ENV.fetch("ENV_DIR")
    run_tests_script = ENV.fetch("RUN_TESTS_SCRIPT")
    test_cmd = JSON.parse(ENV.fetch("TEST_COMMAND_JSON"))
    test_args = JSON.parse(ENV.fetch("TEST_ARGS_JSON"))

    meta = JSON.parse(File.read(File.join(env_dir, "nix-support", "env.json")))
    ruby = meta["ruby"]
    bundle = meta["bundle"]
    extensions = meta["extensions"]
    root_suffix = meta["root_suffix"]
    member_suffix = meta["member_suffix"]

    tmpdir = ENV["TMPDIR"] || "/tmp"
    workspace = File.join(tmpdir, "workspace")
    FileUtils.cp_r(src, workspace)
    FileUtils.chmod_R("u+w", workspace)

    ENV["HOME"] = tmpdir
    ENV["GEM_HOME"] = env_dir
    ENV["GEM_PATH"] = env_dir
    ENV["BUNDLE_IGNORE_CONFIG"] = "1"
    ENV["BUNDLE_FROZEN"] = "true"
    ENV["BUNDLE_VERSION"] = meta["bundler_version"]
    ENV["BUNDLE_GEMFILE"] = "#{workspace}#{root_suffix}/Gemfile"
    ENV["PATH"] = "#{env_dir}/bin:#{ruby}/bin:#{ENV["PATH"]}"
    ENV["RUBYLIB"] = extensions unless extensions.empty?

    Dir.chdir("#{workspace}#{member_suffix}")
    ok = system(bundle, "check")
    raise "bundle check failed" unless ok

    cmd =
      if test_cmd.nil?
        [bundle, "exec", "#{ruby}/bin/ruby", run_tests_script, *test_args]
      else
        [bundle, "exec", *test_cmd, *test_args]
      end
    ok = system(*cmd)
    raise "tests failed" unless ok

    Dir.mkdir(out)
  end
end

begin
  case ARGV[0]
  when "stage1" then DrvRb.stage1
  when "stage2" then DrvRb.stage2
  when "slice" then DrvRb.slice(ARGV.fetch(1), ARGV.fetch(2))
  when "install-gem" then DrvRb.install_gem
  when "assemble" then DrvRb.assemble
  when "package" then DrvRb.package
  when "test" then DrvRb.run_tests
  else
    raise "unknown drvrb command: #{ARGV[0].inspect}"
  end
rescue StandardError => e
  abort "drvrb: #{e.message}"
end
