pkgs: { src, plan, gemInputs, gemFlags }:
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
  manifest = (pkgs.writeText "drvrb-gem-paths.json" (builtins.toJSON (lib.mapAttrs (_: toString) gems))).overrideAttrs {
    __contentAddressed = true;
  };
  suffix = rel: lib.escapeShellArg (lib.optionalString (rel != ".") "/${rel}");
in (pkgs.writeText "drvrb-locked-gems" ''
  export GEM_HOME=${folder} GEM_PATH=${folder}
  export BUNDLE_IGNORE_CONFIG=1 BUNDLE_FROZEN=true BUNDLE_VERSION=${lib.escapeShellArg bundlerVersion}
  extensions=${lib.escapeShellArg localExtensions}
  bundle=${lib.escapeShellArg bundle}
  manifest=${manifest}
  rootSuffix=${suffix plan.root}
  memberSuffix=${suffix plan.member}
'').overrideAttrs { __contentAddressed = true; }
