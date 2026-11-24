{ drvkit, nixpkgs ? null, test ? false }:
pkgs: { src, memberPath ? ".", gemInputs ? {}, gemFlags ? {}, testCommand ? null, testArgs ? [] }:
let
  inherit (pkgs) lib;
  nixpkgsSource = import (drvkit + "/nixpkgs-source.nix") pkgs nixpkgs;
  ruby = pkgs.ruby_4_0;
  dynamic = import (drvkit + "/dynamic.nix") { inherit pkgs; };
  json = value: "builtins.fromJSON ${lib.strings.escapeNixString (builtins.toJSON value)}";
  environment = dynamic {
    name = "drvrb-gems";
    prepare = ''
      export HOME="$TMPDIR" BUNDLE_IGNORE_CONFIG=1 BUNDLE_FROZEN=true BUNDLE_VERSION=system
      ${ruby}/bin/ruby ${./plan.rb} ${lib.escapeShellArg (toString src)} ${lib.escapeShellArg memberPath} > plan.json
    '';
    expression = ''
      let pkgs = import ${nixpkgsSource} { system = "${pkgs.stdenv.hostPlatform.system}"; };
      in import ${./build.nix} pkgs {
        src = builtins.storePath "${src}";
        plan = builtins.fromJSON (builtins.readFile ./plan.json);
        gemInputs = ${json gemInputs};
        gemFlags = ${json gemFlags};
      }
    '';
  };
  common = { __contentAddressed = true; passthru.planner = environment.planner; };
in if test then pkgs.runCommand "drvrb-test" common ''
  source ${environment}
  export HOME="$TMPDIR"
  if [[ -n "$extensions" ]]; then export RUBYLIB="$extensions"; fi
  cp -R ${src} workspace
  chmod -R u+w workspace
  export BUNDLE_GEMFILE="$PWD/workspace$rootSuffix/Gemfile"
  export PATH="$GEM_HOME/bin:${ruby}/bin:$PATH"
  cd "workspace$memberSuffix"
  "$bundle" check
  ${if testCommand == null then ''
    "$bundle" exec ${ruby}/bin/ruby ${./run-tests.rb} ${lib.escapeShellArgs testArgs}
  '' else ''
    "$bundle" exec ${lib.escapeShellArgs (testCommand ++ testArgs)}
  ''}
  mkdir "$out"
'' else pkgs.runCommand "drvrb-package" (common // { nativeBuildInputs = [ pkgs.makeWrapper ]; }) ''
  source ${environment}
  mkdir -p "$out/bin" "$out/nix-support"
  for dir in gems specifications extensions cache plugins build_info; do
    if [[ -e "$GEM_HOME/$dir" ]]; then ln -s "$GEM_HOME/$dir" "$out/$dir"; else mkdir "$out/$dir"; fi
  done
  ln -s "$manifest" "$out/nix-support/gem-paths.json"
  settings=(--set GEM_HOME "$GEM_HOME" --set GEM_PATH "$GEM_PATH" --set BUNDLE_GEMFILE "${src}$rootSuffix/Gemfile"
    --set BUNDLE_IGNORE_CONFIG 1 --set BUNDLE_FROZEN true --set BUNDLE_VERSION "$BUNDLE_VERSION"
    --prefix PATH : "${ruby}/bin:$GEM_HOME/bin")
  if [[ -n "$extensions" ]]; then settings+=(--prefix RUBYLIB : "$extensions"); fi
  makeWrapper "${ruby}/bin/ruby" "$out/bin/ruby" "''${settings[@]}" --add-flags '-rbundler/setup'
  makeWrapper "${ruby}/bin/gem" "$out/bin/gem" "''${settings[@]}"
  makeWrapper "$bundle" "$out/bin/bundle" "''${settings[@]}"
  shopt -s nullglob
  for entry in "$GEM_HOME"/bin/*; do
    name=''${entry##*/}
    [[ -e "$out/bin/$name" ]] || makeWrapper "$bundle" "$out/bin/$name" "''${settings[@]}" --add-flag exec --add-flag "$entry"
  done
  programs=()
  for entry in "${src}$memberSuffix"/{exe,bin}/*; do
    [[ -f "$entry" && -x "$entry" ]] || continue
    name=''${entry##*/}
    if [[ "$name" == bundle || "$name" == ruby || "$name" == gem ]]; then continue; fi
    rm -f "$out/bin/$name"
    makeWrapper "$bundle" "$out/bin/$name" "''${settings[@]}" --add-flag exec --add-flag "$entry"
    programs+=("$name")
  done
  if [[ ''${#programs[@]} == 1 ]]; then
    ln -s "../bin/''${programs[0]}" "$out/nix-support/drvrb-run"
  else
    ln -s ../bin/ruby "$out/nix-support/drvrb-run"
  fi
  "$out/bin/bundle" check
''
