{ drvkit, test ? false }:
pkgs: { src, memberPath ? ".", gemInputs ? {}, gemFlags ? {}, testCommand ? null, testArgs ? [] }:
let
  inherit (pkgs) lib;
  ruby = pkgs.ruby_4_0;
  dynamic = import (drvkit + "/dynamic.nix") { inherit pkgs; };
  json = value: "builtins.fromJSON ${lib.strings.escapeNixString (builtins.toJSON value)}";
in dynamic {
  name = if test then "drvrb-test" else "drvrb-package";
  prepare = ''
    export HOME="$TMPDIR" BUNDLE_IGNORE_CONFIG=1 BUNDLE_FROZEN=true BUNDLE_VERSION=system
    ${ruby}/bin/ruby ${./plan.rb} ${lib.escapeShellArg (toString src)} ${lib.escapeShellArg memberPath} > plan.json
  '';
  expression = ''
    let pkgs = import ${pkgs.path} { system = "${pkgs.stdenv.hostPlatform.system}"; };
    in import ${./build.nix} pkgs {
      src = builtins.storePath "${src}";
      plan = builtins.fromJSON (builtins.readFile ./plan.json);
      gemInputs = ${json gemInputs};
      gemFlags = ${json gemFlags};
      testRunner = builtins.storePath "${./run-tests.rb}";
      testCommand = ${json testCommand};
      testArgs = ${json testArgs};
      test = ${lib.boolToString test};
    }
  '';
}
