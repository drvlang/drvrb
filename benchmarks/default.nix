{ self, system, pkgs }:
let
  upstream = builtins.fetchTree {
    type = "github"; owner = "ruby"; repo = "ruby-bench";
    rev = "c54da6e0161d2eab99e0aa60f75f5108f6cffa2e";
    narHash = "sha256-C1DYyfJ0i6m6KGsk+MeEnZjy59D/awQ+ok4N11B4FBc=";
  };
  project = upstream.outPath + "/benchmarks/graphql";
  env = self.lib.mkPackage { inherit system; src = project; };
in pkgs.runCommand "drvrb-ruby-bench-graphql" { __contentAddressed = true; } ''
  export HOME="$TMPDIR" HARNESS=once RESULT_JSON_PATH="$TMPDIR/trial.json"
  export PATH="${env}/bin:$PATH"
  ruby -rracc/cparse -e 'abort unless $LOADED_FEATURES.grep(%r{racc/cparse\.(so|bundle)$}).any?'
  # The harness uses Fiddle to read process memory on Darwin. Its own bundled
  # gem is supplied by Ruby, outside the GraphQL workload's locked gems.
  fiddle=$(${pkgs.ruby_4_0}/bin/ruby -rrubygems -e 'puts Gem::Specification.find_by_name("fiddle").full_require_paths.join(File::PATH_SEPARATOR)')
  ruby -I "$fiddle" ${project}/benchmark.rb
  ruby -rjson -e 'trial = JSON.parse(File.read(ARGV.fetch(0))); abort unless trial.fetch("rss").positive? && trial.fetch("maxrss").positive?' "$RESULT_JSON_PATH"
  ruby -rgraphql -e 'doc = GraphQL.parse(File.read(ARGV.first)); abort if doc.definitions.empty?; puts doc.definitions.size' ${project}/negotiate.gql > "$out"
''
