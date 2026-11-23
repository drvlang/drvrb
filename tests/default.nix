{ self, system, pkgs }:
let
  root = ./workspace;
  commands = (builtins.fromJSON (builtins.readFile ./workspace/drvlang.json)).commands;
  srcForTarget = { target, ... }: self.lib.projectSource {
    inherit root;
    files = [ ./workspace/Gemfile ./workspace/Gemfile.lock ./workspace/pkg/greeting (root + "/${target}") ];
  };
  ws = self.lib.mkMonorepoFlake { inherit srcForTarget commands; };
in pkgs.runCommand "drvrb-workspace" { tests = builtins.attrValues ws.checks.${system}; } ''
  test "$(${ws.apps.${system}.hello.program} 'Ruby gems')" = 'hello: hello Ruby gems'
  test "$(${ws.apps.${system}.worker.program} 'Ruby gems')" = 'worker: hello Ruby gems'
  touch "$out"
''
