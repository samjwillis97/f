{
  description = "My tmux session manager";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;
        
        f = pkgs.writeShellScriptBin "f" (builtins.readFile ./f.sh);
      in
      {
        packages.default = f;
        
        apps.default = {
          type = "app";
          program = "${f}/bin/f";
        };
        
        devShells.default = pkgs.mkShell {
          buildInputs = [
            f
            pkgs.git
            pkgs.tmux
            pkgs.direnv
            pkgs.fzf
          ];
        };
      });
}
