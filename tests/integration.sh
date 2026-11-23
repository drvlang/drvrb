#!/usr/bin/env bash
set -euo pipefail
export NIX_CONFIG="${NIX_CONFIG:-}
allow-import-from-derivation = false"
tool=$(nix flake archive --json | jq -er .path)
cli=$(nix build --no-link --print-out-paths .#drvrb)/bin/drvrb
system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -R tests/workspace "$tmp/project"
cd "$tmp/project"
cat > flake.nix <<NIX
{
  inputs.drvrb.url = "path:$tool";
  outputs = { drvrb, ... }: drvrb.lib.mkMonorepoFlake {
    commands = (builtins.fromJSON (builtins.readFile ./drvlang.json)).commands;
    srcForTarget = { target, ... }: drvrb.lib.projectSource {
      root = ./.;
      files = [ ./Gemfile ./Gemfile.lock ./pkg/greeting (./. + "/\${target}") ];
    };
  };
}
NIX
nix flake lock
for kind in packages checks; do
  path_of() { nix eval --raw "path:$PWD#$kind.$system.$1.drvPath"; }
  hello=$(path_of hello)
  worker=$(path_of worker)
  echo docs >> notes.md
  [[ $(path_of hello) == "$hello" && $(path_of worker) == "$worker" ]]
  echo '# worker only' >> cmd/worker/bin/worker
  [[ $(path_of hello) == "$hello" && $(path_of worker) != "$worker" ]]
  worker=$(path_of worker)
  echo '# common edit' >> pkg/greeting/lib/greeting.rb
  [[ $(path_of hello) != "$hello" && $(path_of worker) != "$worker" ]]
done
nix flake check "path:$PWD"
before=$("$cli" build -C . hello -o "$tmp/first")
[[ $("$cli" run -C . hello -- 'two words') == 'hello: hello two words' ]]
[[ $(nix run "path:$PWD#worker" -- 'two words') == 'worker: hello two words' ]]
"$cli" test -C . hello -- --seed 314
GEM_HOME="$before" GEM_PATH="$before" "$before/bin/ruby" -rgreeting -e 'abort unless Greeting.for("Nix") == "hello Nix"'
[[ -f "$before/specifications/greeting-1.0.0.gemspec" && -d "$before/gems/base64-0.3.0" ]]
manifest=nix-support/gem-paths.json
gem_path() { jq -er --arg name "$2" '.[$name]' "$1/$manifest"; }
# On realization Nix resolves the local gem's dependency to its CA store path.
greeting_drv=$(nix-store -q --deriver "$(gem_path "$before" greeting)")
nix-store -q --references "$greeting_drv" | grep -Fx "$(gem_path "$before" base64)"
nix path-info --json "$before" "$(realpath "$before")" "$(gem_path "$before" greeting)" "$(gem_path "$before" base64)" |
  jq -e 'all(.[]; .ca | startswith("fixed:r:sha256:"))'
# A pure-Ruby gem ignores this extra build tool. Its installed gem, native
# dependent and public GEM_HOME should all resolve to the previous outputs.
equivalent=$("$cli" build -C . hello --no-link --options '{"gemInputs":{"base64":["pkg-config"]}}')
[[ "$equivalent" == "$before" ]]
echo 'def Greeting.revision = 2' >> pkg/greeting/lib/greeting.rb
after=$("$cli" build -C . hello --no-link)
[[ $("$after/bin/ruby" -rgreeting -e 'puts Greeting.revision') == 2 ]]
[[ $(gem_path "$before" greeting) != "$(gem_path "$after" greeting)" ]]
[[ $(gem_path "$before" base64) == "$(gem_path "$after" base64)" ]]
# Change only the native Gemfile and lock to select a new version of minitest.
cp "$tool/tests/update/Gemfile" "$tool/tests/update/Gemfile.lock" .
updated=$("$cli" build -C . hello --no-link)
[[ $(gem_path "$after" base64) == "$(gem_path "$updated" base64)" ]]
[[ $(gem_path "$after" greeting) == "$(gem_path "$updated" greeting)" ]]
[[ $(gem_path "$after" minitest) != "$(gem_path "$updated" minitest)" ]]
"$cli" test -C . hello
echo 'raise "drvrb expected failure"' >> cmd/hello/test/greeting_test.rb
if "$cli" test -C . hello >"$tmp/error" 2>&1; then exit 1; fi
grep -q 'drvrb expected failure' "$tmp/error" || { cat "$tmp/error"; exit 1; }
"$cli" test -C . worker
sed 's/sha256=[a-f0-9]*/sha256=0000000000000000000000000000000000000000000000000000000000000001/' Gemfile.lock > corrupted
mv corrupted Gemfile.lock
if "$cli" build -C . worker --no-link >"$tmp/error" 2>&1; then exit 1; fi
grep -qi 'hash mismatch' "$tmp/error" || { cat "$tmp/error"; exit 1; }
