# Optimizing drvrb for CI

Across all seven CIBench CI cases, replacing `drvkit/dynamic.nix`, `nix-instantiate`, `nixpkgsSource`, Perl `buildEnv`, `makeWrapper`, and unconditional `stdenv`/`gcc` on pure-Ruby gems with a self-contained Ruby 4.0 two-stage Nix daemon ATerm planner and native gem builder reduced cold builds from 36.97 s to 2.73 s (13.54× faster; 1.56× faster than Nixpkgs `bundlerEnv`), remote cache restores from 10.18 s / 227.2 MiB to 1.86 s / 43.7 MiB (5.47× faster, 80.8% less traffic), local warm checks from 1.20 s to 0.93 s (1.29× faster), remote edits from 35.48 s / 227.2 MiB to 2.60 s / 43.6 MiB (13.65× faster; 1.79× faster than `bundlerEnv` with 76.0% less traffic), local edits from 22.11 s to 1.81 s (12.22× faster; 1.53× faster than `bundlerEnv`), remote dependency updates from 36.60 s / 227.2 MiB to 3.00 s / 43.6 MiB (12.20× faster; 1.79× faster than `bundlerEnv` with 76.0% less traffic), and local dependency updates from 24.60 s to 2.28 s (10.79× faster; 1.42× faster than `bundlerEnv`).

CIBench installs a small Ruby script (`bin/encode`) depending on `base64` from `Gemfile.lock` and checks its output. The source edit modifies `bin/encode` and the expected output without changing `Gemfile` or `Gemfile.lock`. The independent dependency update upgrades `base64` from `0.2.0` to `0.3.0` in `Gemfile` and `Gemfile.lock` without any separate Nix `gemset.nix` regeneration.

| CIBench case | drvrb `c07fe76` (s) | drvrb optimized (s) | `bundlerEnv` (s) | drvrb cache transfer (before → after) | drvrb builds (before → after) | drvrb peak RAM (before → after) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| cold | 36.97 | 2.73 | 4.26 | 0.0 → 0.0 MiB | 10 → 6 | 1814 → 601 MiB |
| remote-warm | 10.18 | 1.86 | 1.66 | 227.2 → 43.7 MiB | 0 → 0 | 1779 → 584 MiB |
| local-warm | 1.20 | 0.93 | 0.91 | 0.0 → 0.0 MiB | 0 → 0 | 372 → 334 MiB |
| edit-remote | 35.48 | 2.60 | 4.66 | 227.2 → 43.6 MiB | 3 → 3 | 1772 → 603 MiB |
| edit-local | 22.11 | 1.81 | 2.77 | 0.0 → 0.0 MiB | 3 → 3 | 492 → 353 MiB |
| dependency-remote | 36.60 | 3.00 | 5.36 | 227.2 → 43.6 MiB | 9 → 6 | 1771 → 605 MiB |
| dependency-local | 24.60 | 2.28 | 3.23 | 0.0 → 0.0 MiB | 9 → 6 | 495 → 357 MiB |

Times are medians of two trials for `c07fe76`, three trials for the optimized tree, and five trials for the shared Nixpkgs `bundlerEnv` comparator, run in alternating order (`before-1`, `after-1` ×2, `before-2`, `after-2`) with no competing host workloads. Both builders used Ruby 4.0.10. Each sample timed evaluation and realization of the package and check together. [Individual timings, build counts, cache traffic, peak memory, and realized outputs](cibench-ci-optimizations-2026-11-27.csv)

## Summary of optimizations

1. **Self-contained Ruby 4.0 direct Nix daemon ATerm planner (`drvrb.rb`, `package.nix`, `flake.nix`)**: Replaced `drvkit/dynamic.nix`, `nix-instantiate`, `nixpkgsSource` (202 MiB), `build.nix`, and `plan.rb` with a single stdlib-only Ruby 4.0 script communicating directly with the recursive Nix daemon over protocol 1.21 (`wopQueryValidPaths`, `wopAddTextToStore`). Removed `pkgs.nix`, `boost`, `icu4c`, `aws-sdk`, `curl`, and Nixpkgs evaluation from consumer builds.
2. **Two-stage dynamic derivation with lazy native toolchain realization (`drvrb.rb`, `package.nix`)**: Stage 1 parses `Gemfile`/`Gemfile.lock` and emits `builtin:fetchurl` derivations (preserving stock cache paths). Stage 2 inspects each fetched `.gem` archive's `Gem::Package#spec.extensions` and only attaches `stdenv`, `gcc`, `pkg-config`, and `git` (passed as unrealized `.drv` references via `builtins.unsafeDiscardOutputDependency`) to gems that actually compile C extensions or build from local workspace paths. Pure-Ruby and precompiled platform gems install directly with `Gem::Installer` using only `ruby_4_0`, avoiding `gcc-16.2.0` (105 MiB), `binutils`, `pkg-config`, and `stdenv`.
3. **Zero-`stdenv`, zero-Perl `GEM_HOME` assembly and wrapper generation (`drvrb.rb`)**: Replaced Perl `buildEnv` (`builder.pl`), `writeText` metadata wrappers, and `pkgs.runCommand` + `makeWrapper` (`stdenv-linux-no-cc`) with pure-Ruby `--disable-gems` `assemble`, `package`, and `test` builders, lazy `require` loading, and direct `ruby -rbundler/setup` wrappers for Ruby entrypoints.

## Correctness checks

- Realized package and check outputs were deterministic across all three optimized trials and matched between `cold`, `remote-warm`, and `local-warm`, between `edit-remote` and `edit-local`, and between `dependency-remote` and `dependency-local`.
- `nix flake check -L --option allow-import-from-derivation false` passed all checks:
  - `checks.x86_64-linux.benchmark` (upstream `ruby-bench` GraphQL parser with `racc` C extension compiled via lazy `stdenv` + `pkg-config`)
  - `checks.x86_64-linux.platform` (precompiled native `ffi` platform gem installed without `stdenv`)
  - `checks.x86_64-linux.workspace` (multi-member monorepo with local C-extension gem `greeting`, `base64`, and `minitest`)
  - `checks.x86_64-linux.cli`
- `nix flake show --all-systems` (`x86_64-linux`, `aarch64-linux`, `aarch64-darwin`) and `tests/integration.sh` (shared planner identity, `srcForTarget` isolation, `drvrb build`/`run`/`test`, `gem-paths.json`, resolved CA references, floating CA early cutoff with `gemInputs`, local gem edit, lockfile update, failing test exit code, and corrupted SHA-256 hash mismatch) passed.

## Reproduction

The runner used x86_64 Linux, an Intel Core i7-1280P, Nix 2.35.3, four logical CPUs (16–19), four jobs, four cores per builder, 8 GiB RAM, and zero swap. Sandboxing was enabled and IFD disabled. The simulated project cache used 5 ms latency and 100 MiB/s aggregate bandwidth. Both builders used the same local mirror of signed NixOS packages populated from `drvkit/cibench/results/bootstrap/rb.txt`. Cold jobs started with an empty local store and project cache. Subsequent cases independently used the original job's local store or its published project cache. The recorded runner was `/nix/store/vpysz8ih9lhm154cjaamrncwjn08njp6-cibench-0.1.0`.

```sh
work=$(mktemp -d)
stock="file://$work/stock"
nix copy --from https://cache.nixos.org --to "$stock?compression=zstd&compression-level=1" \
  --stdin < ../drvkit/cibench/results/bootstrap/rb.txt
runner="$(nix build --impure --no-link --print-out-paths -f ../drvkit/cibench)/bin/cibench"
mkdir "$work/before"
git archive c07fe76 | tar -x -C "$work/before"
run() {
  taskset -c 16-19 "$runner" rb --builder "$1" --out "$work/$2" --trials "$3" \
    --cpus 4 --memory-mib 8192 --latency-ms 5 --bandwidth-mib-s 100 \
    --upstream "$stock?priority=40"
}
run "$work/before" before-1 1
run "$PWD" after-1 2
run "$work/before" before-2 1
run "$PWD" after-2 1
```
