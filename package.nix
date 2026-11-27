{ test ? false }:
pkgs: { src, memberPath ? ".", gemInputs ? {}, gemFlags ? {}, testCommand ? null, testArgs ? [] }:
let
  inherit (pkgs) lib;
  ruby = pkgs.ruby_4_0;
  system = pkgs.stdenv.hostPlatform.system;
  script = ./drvrb.rb;
  gemInputsSpec = lib.mapAttrs (_: names: map (n: {
    drv = builtins.unsafeDiscardOutputDependency pkgs.${n}.drvPath;
    out = builtins.unsafeDiscardStringContext (toString pkgs.${n});
  }) names) gemInputs;

  stage1 = builtins.derivation {
    name = "drvrb-gems.drv.drv";
    inherit system;
    builder = "${ruby}/bin/ruby";
    args = [ script "stage1" ];
    SRC = "${src}";
    MEMBER_PATH = memberPath;
    RUBY = "${ruby}";
    SCRIPT = "${script}";
    SYSTEM = system;
    STDENV_DRV = builtins.unsafeDiscardOutputDependency pkgs.stdenv.drvPath;
    STDENV_OUT = builtins.unsafeDiscardStringContext (toString pkgs.stdenv);
    PKG_CONFIG_DRV = builtins.unsafeDiscardOutputDependency pkgs.pkg-config.drvPath;
    PKG_CONFIG_OUT = builtins.unsafeDiscardStringContext (toString pkgs.pkg-config);
    GIT_DRV = builtins.unsafeDiscardOutputDependency pkgs.gitMinimal.drvPath;
    GIT_OUT = builtins.unsafeDiscardStringContext (toString pkgs.gitMinimal);
    BASH_DRV = builtins.unsafeDiscardOutputDependency pkgs.bash.drvPath;
    BASH_OUT = builtins.unsafeDiscardStringContext (toString pkgs.bash);
    GEM_INPUTS_JSON = builtins.toJSON gemInputsSpec;
    GEM_FLAGS_JSON = builtins.toJSON gemFlags;
    requiredSystemFeatures = [ "recursive-nix" ];
    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";
  };

  stage2 = builtins.outputOf stage1.outPath "out";
  environment = builtins.outputOf stage2 "out";

  drv = builtins.derivation ({
    name = if test then "drvrb-test" else "drvrb-package";
    inherit system;
    builder = "${ruby}/bin/ruby";
    args = [ "--disable-gems" script (if test then "test" else "package") ];
    SRC = "${src}";
    ENV_DIR = environment;
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
  } // lib.optionalAttrs test {
    RUN_TESTS_SCRIPT = "${./run-tests.rb}";
    TEST_COMMAND_JSON = builtins.toJSON testCommand;
    TEST_ARGS_JSON = builtins.toJSON testArgs;
  });
in drv // { passthru = { planner = stage1; }; }
