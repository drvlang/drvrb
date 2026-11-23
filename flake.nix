{
  description = "Build a RubyGems home one locked gem at a time";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/2786a2a72088ecf32aea5b3ec52099e6a7cff78f";
  inputs.drvkit = { url = "github:drvlang/drvkit"; flake = false; };
  outputs = { self, nixpkgs, drvkit }: import drvkit {
    inherit self nixpkgs;
    name = "drvrb";
    systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
    mkPackage = import ./package.nix { inherit drvkit; };
    mkTest = import ./package.nix { inherit drvkit; test = true; };
    selectTarget = { src, target, ... }: { inherit src; memberPath = target; };
    mkApp = pkgs: args: pkg:
      let program = args.program or null;
      in assert pkgs.lib.assertMsg (program == null || (builtins.match "[^/]+" program != null &&
        !(builtins.elem program [ "." ".." ]))) "program must be an executable basename";
      { type = "app"; program = if program == null then "${pkg}/nix-support/drvrb-run" else "${pkg}/bin/${program}"; };
    extraChecks = system: let args = { inherit self system; pkgs = nixpkgs.legacyPackages.${system}; }; in {
      benchmark = import ./benchmarks args;
      workspace = import ./tests args;
      platform = let env = self.lib.mkPackage {
        inherit system;
        src = self.lib.projectSource {
          root = ./tests/platforms;
          files = [ ./tests/platforms/Gemfile ./tests/platforms/Gemfile.lock ];
        };
      }; in args.pkgs.runCommand "drvrb-native-platform" {} ''
        ${env}/bin/ruby -rffi -e 'abort if Gem.loaded_specs.fetch("ffi").platform == "ruby"; puts FFI::MemoryPointer.new(:int).write_int(42).read_int' > "$out"
        grep -qx 42 "$out"
      '';
    };
  };
}
