{
  description = "Build a cargo project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-analyzer-src.follows = "";
    };

    flake-utils.url = "github:numtide/flake-utils";

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, crane, fenix, flake-utils, advisory-db, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        inherit (pkgs) lib;

        craneLib = crane.lib.${system};
        src = craneLib.cleanCargoSource (craneLib.path ./.);

        # Common arguments can be set here to avoid repeating them later
        commonArgs = {
          inherit src;
          strictDeps = true;

          buildInputs = [
            pkgs.pkg-config
            pkgs.libiconv
            pkgs.openssl
            # Add additional build inputs here
          ] ++ lib.optionals pkgs.stdenv.isDarwin [
            # Additional darwin specific inputs can be set here
            pkgs.libiconv
            pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          ];

          # Additional environment variables can be set directly
          OPENSSL_DIR = pkgs.openssl.dev;
        };

        craneLibLLvmTools = craneLib.overrideToolchain
          (fenix.packages.${system}.complete.withComponents [
            "cargo"
            "llvm-tools"
            "rustc"
          ]);

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Build the actual crate itself, reusing the dependency
        # artifacts from above.
        f = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
        });

        f-fzf-tmux-wrapper = pkgs.writeShellScriptBin "f-fzf-tmux-wrapper"
        ''
          selected="$(${f}/bin/f list | ${pkgs.fzf}/bin/fzf -i --scheme=path --print-query)"
          retVal=$?

          if [ $retVal -eq 1 ]; then
            selected=$(${f}/bin/f "$selected" 2>/dev/null)
            retVal=$?
          else
            selected=$(echo "$selected" | sed -n 2p)
          fi

          if [ $retVal -ne 0 ]; then
            echo "Unable to get repo or branch: $selected"
            exit 1
          fi

          repo_dir=$(dirname "$selected")
          owner_dir=$(dirname "$repo_dir")
          branch_name=$(basename "$selected")
          repo_name=$(basename "$repo_dir")
          owner_name=$(basename "$owner_dir")

          selected_name="$owner_name/$repo_name/$branch_name"
          tmux_running=$(pgrep tmux)

          if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
              tmux new-session -s $selected_name -c $selected
              exit 0
          fi

          if ! tmux has-session -t=$selected_name 2> /dev/null; then
              tmux new-session -ds $selected_name -c $selected
          fi

          if [[ -z $TMUX ]]; then
              tmux attach-session -t $selected_name
              exit 0
          fi

          tmux switch-client -t $selected_name
        '';

      in
      {
        checks = {
          # Build the crate as part of `nix flake check` for convenience
          my-crate = f;

          # Run clippy (and deny all warnings) on the crate source,
          # again, resuing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          my-crate-clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          });

          my-crate-doc = craneLib.cargoDoc (commonArgs // {
            inherit cargoArtifacts;
          });

          # Check formatting
          my-crate-fmt = craneLib.cargoFmt {
            inherit src;
          };

          # Audit dependencies
          my-crate-audit = craneLib.cargoAudit {
            inherit src advisory-db;
          };

          # Audit licenses
          my-crate-deny = craneLib.cargoDeny {
            inherit src;
          };

          # Run tests with cargo-nextest
          # Consider setting `doCheck = false` on `my-crate` if you do not want
          # the tests to run twice
          my-crate-nextest = craneLib.cargoNextest (commonArgs // {
            inherit cargoArtifacts;
            partitions = 1;
            partitionType = "count";
          });
        };

        packages = {
          default = f;
          f-tmux = f-fzf-tmux-wrapper;
        } // lib.optionalAttrs (!pkgs.stdenv.isDarwin) {
          my-crate-llvm-coverage = craneLibLLvmTools.cargoLlvmCov (commonArgs // {
            inherit cargoArtifacts;
          });
        };

        apps.default = flake-utils.lib.mkApp {
          drv = f;
        };

        apps.f = flake-utils.lib.mkApp {
          drv = f;
        };

        apps.f-tmux = flake-utils.lib.mkApp {
          drv = f-fzf-tmux-wrapper;
        };

        devShells.default = craneLib.devShell {
          # Inherit inputs from checks.
          checks = self.checks.${system};

          # Additional dev-shell environment variables can be set directly
          # MY_CUSTOM_DEVELOPMENT_VAR = "something else";
          inputsFrom = [ f ];

          # Extra inputs can be added here; cargo and rustc are provided by default.
          packages = [
            f
            f-fzf-tmux-wrapper
            # pkgs.ripgrep
          ];
        };
      });
}
