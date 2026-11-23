pkgs: { src, plan, gemInputs, gemFlags, test, testCommand, testArgs, testRunner }:
let
  inherit (pkgs) lib;
  ruby = pkgs.ruby_4_0;
  projectPath = rel: src + lib.optionalString (rel != ".") "/${rel}";
  gem = name: spec: let
    deps = map (n: gems.${n}) spec.deps;
    closure = lib.unique (lib.concatMap (d: [ d ] ++ d.runtimeDeps) deps);
    local = spec ? path;
    archive = if local then null else pkgs.fetchurl {
      name = "${spec.full}.gem"; inherit (spec) url sha256;
    };
    localSrc = if !local then null else builtins.path {
      # Copy this member on its own so a sibling edit preserves the gem's recipe.
      path = /. + builtins.unsafeDiscardStringContext (toString (projectPath spec.path));
      name = "source-${name}";
    };
  in pkgs.stdenv.mkDerivation {
    __contentAddressed = true;
    pname = "drvrb-${name}";
    inherit (spec) version;
    dontUnpack = true;
    strictDeps = true;
    nativeBuildInputs = [ ruby pkgs.pkg-config ] ++ lib.optional local pkgs.gitMinimal;
    buildInputs = map (n: pkgs.${n}) (gemInputs.${name} or []);
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      export HOME="$TMPDIR" GEM_HOME="$out" GEM_PATH=${lib.escapeShellArg (lib.concatStringsSep ":" (map toString closure))}
      export SOURCE_DATE_EPOCH=1
      ${if local then ''
        cp -R ${localSrc} source
        chmod -R u+w source
        cd source
        # Gems commonly enumerate their source files using git ls-files.
        git init -q
        git add --all
        gem build ${lib.escapeShellArg spec.gemspec} --output "$TMPDIR/package.gem"
      '' else ""}
      archive=${if local then ''"$TMPDIR/package.gem"'' else lib.escapeShellArg (toString archive)}
      ruby -rrubygems/package -e 's = Gem::Package.new(ARGV[0]).spec; abort "gem identity: expected #{ARGV[1]}, got #{s.full_name}" unless s.full_name == ARGV[1]' "$archive" ${lib.escapeShellArg spec.full}
      gem install --norc --env-shebang --local --ignore-dependencies --no-document --install-dir "$out" "$archive" -- ${lib.escapeShellArgs (gemFlags.${name} or [])}
      if [[ -d "$out/bin" ]]; then patchShebangs --build "$out/bin"; fi
    '';
    passthru.runtimeDeps = closure;
  };
  gems = lib.mapAttrs gem plan.gems;
  folder = (pkgs.buildEnv {
    name = "drvrb-gem-home";
    paths = builtins.attrValues gems;
    pathsToLink = [ "/gems" "/specifications" "/extensions" "/cache" "/plugins" "/build_info" "/bin" ];
  }).overrideAttrs { __contentAddressed = true; };
  bundle = if gems ? bundler then "${gems.bundler}/bin/bundle" else "${ruby}/bin/bundle";
  bundlerVersion = if gems ? bundler then plan.gems.bundler.version else "system";
  # Bundler uses the checkout as the load path of a path gem. Its extension
  # was compiled inside the gem derivation, away from that read-only checkout.
  localExtensions = lib.concatStringsSep ":" (lib.mapAttrsToList
    (name: spec: "${gems.${name}}/${spec.extensions}") (lib.filterAttrs (_: spec: spec ? extensions) plan.gems));
  gemEnv = ''
    export GEM_HOME=${folder} GEM_PATH=${folder}
    export BUNDLE_IGNORE_CONFIG=1 BUNDLE_FROZEN=true BUNDLE_VERSION=${lib.escapeShellArg bundlerVersion}
    ${lib.optionalString (localExtensions != "") ''export RUBYLIB=${lib.escapeShellArg localExtensions}''}
  '';
  root = projectPath plan.root;
  member = projectPath plan.member;
  manifest = (pkgs.writeText "drvrb-gem-paths.json" (builtins.toJSON (lib.mapAttrs (_: toString) gems))).overrideAttrs {
    __contentAddressed = true;
  };
  package = pkgs.runCommand "drvrb-environment" {
    __contentAddressed = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
  } ''
    mkdir -p "$out/bin" "$out/nix-support"
    for dir in gems specifications extensions cache plugins build_info; do
      if [[ -e ${folder}/$dir ]]; then ln -s "${folder}/$dir" "$out/$dir"; else mkdir "$out/$dir"; fi
    done
    ln -s ${manifest} "$out/nix-support/gem-paths.json"
    settings=(--set GEM_HOME "${folder}" --set GEM_PATH "${folder}" --set BUNDLE_GEMFILE ${lib.escapeShellArg "${root}/Gemfile"}
      --set BUNDLE_IGNORE_CONFIG 1 --set BUNDLE_FROZEN true --set BUNDLE_VERSION ${lib.escapeShellArg bundlerVersion}
      --prefix PATH : "${ruby}/bin:${folder}/bin")
    ${lib.optionalString (localExtensions != "") ''settings+=(--prefix RUBYLIB : ${lib.escapeShellArg localExtensions})''}
    makeWrapper "${ruby}/bin/ruby" "$out/bin/ruby" "''${settings[@]}" --add-flags '-rbundler/setup'
    makeWrapper "${ruby}/bin/gem" "$out/bin/gem" "''${settings[@]}"
    makeWrapper ${bundle} "$out/bin/bundle" "''${settings[@]}"
    shopt -s nullglob
    for entry in ${folder}/bin/*; do
      name=''${entry##*/}
      [[ -e "$out/bin/$name" ]] || makeWrapper ${bundle} "$out/bin/$name" "''${settings[@]}" --add-flag exec --add-flag "$entry"
    done
    programs=()
    for entry in ${lib.escapeShellArg (toString member)}/{exe,bin}/*; do
      [[ -f "$entry" && -x "$entry" ]] || continue
      name=''${entry##*/}
      if [[ "$name" == bundle || "$name" == ruby || "$name" == gem ]]; then continue; fi
      rm -f "$out/bin/$name"
      makeWrapper ${bundle} "$out/bin/$name" "''${settings[@]}" --add-flag exec --add-flag "$entry"
      programs+=("$name")
    done
    if [[ ''${#programs[@]} == 1 ]]; then
      ln -s "../bin/''${programs[0]}" "$out/nix-support/drvrb-run"
    else
      ln -s ../bin/ruby "$out/nix-support/drvrb-run"
    fi
    "$out/bin/bundle" check
  '';
in if !test then package else pkgs.runCommand "drvrb-tests" { __contentAddressed = true; } ''
  export HOME="$TMPDIR"
  ${gemEnv}
  cp -R ${src} workspace
  chmod -R u+w workspace
  export BUNDLE_GEMFILE="$PWD/workspace/"${lib.escapeShellArg "${plan.root}/Gemfile"}
  export PATH="${folder}/bin:${ruby}/bin:$PATH"
  cd "workspace/"${lib.escapeShellArg plan.member}
  ${bundle} check
  ${if testCommand == null then ''
    ${bundle} exec ${ruby}/bin/ruby ${testRunner} ${lib.escapeShellArgs testArgs}
  '' else ''
    ${bundle} exec ${lib.escapeShellArgs (testCommand ++ testArgs)}
  ''}
  mkdir "$out"
''
