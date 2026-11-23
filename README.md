# drvrb

Build a RubyGems installation from a checksummed `Gemfile.lock`. Each selected gem has its own Nix derivation, including compilation of native extensions. drvrb joins the installed gems into one read-only `GEM_HOME`. Your CI cache can reuse individual gems when another dependency changes.

## Build, test, and run

Enable `nix-command flakes ca-derivations dynamic-derivations recursive-nix` in the client and daemon. The builder needs the `recursive-nix` system feature. drvrb pins MRI Ruby 4.0 and supports x86-64 and AArch64 Linux and Apple Silicon macOS.

```sh
nix run github:drvlang/drvrb -- build -C ./app -o result
./result/bin/bundle check
./result/bin/ruby -e 'puts Gem.dir'
nix run github:drvlang/drvrb -- test -C ./app
nix run github:drvlang/drvrb -- run -C ./app -- 'two words'
```

The result contains the usual `gems/`, `specifications/`, `extensions/`, and `bin/` directories. Its Ruby and Bundler wrappers use the assembled folder. `nix-support/gem-paths.json` maps gem names to their individual store outputs. Installed gems, the assembled folder, and tests use floating content addresses by default. If a new recipe installs identical files and store references, its consumers can reuse the original gem. Publish the build and its trace with `nix copy --to "$cache" .#hello` for a flake target named `hello`.

When exactly one project executable is present under `exe/` or `bin/`, `run` selects it. Otherwise it runs Ruby. Select an executable explicitly with `--options '{"program":"rake"}'`. Tests use a project's Rake test task, RSpec, or Ruby test files. Set a different command with, for example, `--options '{"testCommand":["rake","spec"]}'`. Arguments after `--` go to the program or test runner.

## Dependencies

Commit `Gemfile` and `Gemfile.lock`. Run `bundle lock --add-checksums` with modern Bundler if your registry entries lack SHA-256 checksums. Update gems with Bundler as usual. drvrb verifies the selected platform's archive and installs it offline, with its locked dependencies available to extension builds.

This release supports public HTTPS gem registries, ordinary precompiled platform variants, and checked-in `path:` gems with a gemspec inside the selected workspace. Git sources, Bundler override sections, and RubyGems 4.1 content-addressed archives are outside its current support. Supply system libraries and extension flags per gem using, for example, `gemInputs.pg = [ "libpq" ];` and `gemFlags.pg = [ "--with-pg-config=pg_config" ];` in Nix.

## Flakes and monorepos

A single project can expose packages, checks, and an app:

```nix
{
  inputs.drvrb.url = "github:drvlang/drvrb";
  outputs = { drvrb, ... }: drvrb.lib.mkFlake {
    src = drvrb.lib.projectSource {
      root = ./.;
      files = [ ./Gemfile ./Gemfile.lock ./bin ./lib ./test ];
    };
  };
}
```

Include any gemspecs, assets, and other files your project reads. For named commands sharing a workspace Gemfile and a local gem, put the target map in `drvlang.json`, then reuse it in the flake:

```json
{ "commands": { "hello": "cmd/hello", "worker": "cmd/worker" } }
```

```nix
outputs = { drvrb, ... }: drvrb.lib.mkMonorepoFlake {
  commands = (builtins.fromJSON (builtins.readFile ./drvlang.json)).commands;
  srcForTarget = { target, ... }: drvrb.lib.projectSource {
    root = ./.;
    files = [ ./Gemfile ./Gemfile.lock ./pkg/greeting (./. + "/${target}") ];
  };
};
```

Use `nix build .#hello`, `nix run .#worker -- world`, or `drvrb test worker`. A member can also have its own Gemfile and lock. [Working workspace](tests/workspace)

## Benchmark

`nix run .#bench -- --runs 5` builds Ruby's upstream GraphQL benchmark environment. It compiles Racc's C extension, runs the upstream parser on the supplied query ten times per trial, and checks the parsed document. The Rust runner times repeat workloads with the gem derivations cached. [Pinned workload](https://github.com/ruby/ruby-bench/tree/c54da6e0161d2eab99e0aa60f75f5108f6cffa2e/benchmarks/graphql) · [Benchmark definition](benchmarks/default.nix)
