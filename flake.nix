{
  description = "GitOps deployment for NixOS using FlakeHub";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    flake-parts.url = "https://flakehub.com/f/hercules-ci/flake-parts/*";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        inputs.flake-parts.flakeModules.partitions
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # Partition development tools to avoid polluting consumers' lockfiles
      partitionedAttrs = {
        devShells = "dev";
        checks = "dev";
        apps = "dev";
      };

      partitions.dev = {
        extraInputsFlake = ./dev;
        module.imports = [
          ./dev/flake-module.nix
        ];
      };

      flake = let
        overlay = final: _prev: {
          flakehub-deploy-runner = final.callPackage ./packages/flakehub-deploy-runner {};
          flakehub-webhook-handler = final.callPackage ./packages/flakehub-webhook-handler {};
        };
      in {
        overlays = rec {
          flakehub-deploy = overlay;
          default = flakehub-deploy;
        };

        nixosModules = rec {
          flakehub-deploy = {
            imports = [./modules];
            nixpkgs.overlays = [overlay];
          };
          default = flakehub-deploy;
        };
      };

      perSystem = {pkgs, ...}: {
        packages = {
          flakehub-deploy-runner = pkgs.callPackage ./packages/flakehub-deploy-runner {};
          flakehub-webhook-handler = pkgs.callPackage ./packages/flakehub-webhook-handler {};
        };
      };
    };
}
