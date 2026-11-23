{ self, system, pkgs }:
let
  upstream = builtins.fetchTree {
    type = "github"; owner = "ruby"; repo = "ruby-bench";
    rev = "c54da6e0161d2eab99e0aa60f75f5108f6cffa2e";
    narHash = "sha256-C1DYyfJ0i6m6KGsk+MeEnZjy59D/awQ+ok4N11B4FBc=";
  };
  project = upstream.outPath + "/benchmarks/graphql";
  env = self.lib.mkPackage { inherit system; src = project; };
in pkgs.runCommand "drvrb-ruby-bench-graphql" {} ''
  export HOME="$TMPDIR" HARNESS=once RESULT_JSON_PATH="$TMPDIR/trial.json"
  export PATH="${env}/bin:$PATH"
  ruby -rracc/cparse -e 'abort unless $LOADED_FEATURES.grep(%r{racc/cparse\.(so|bundle)$}).any?'
  ruby ${project}/benchmark.rb
  test -s "$RESULT_JSON_PATH"
  ruby -rgraphql -e 'doc = GraphQL.parse(File.read(ARGV.first)); abort if doc.definitions.empty?; puts doc.definitions.size' ${project}/negotiate.gql > "$out"
''
