{
  description = "GitOps deployment for NixOS using FlakeHub";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    flake-parts.url = "https://flakehub.com/f/hercules-ci/flake-parts/*";
    flake-root.url = "github:srid/flake-root";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        inputs.flake-root.flakeModule
        inputs.treefmt-nix.flakeModule
      ];

      systems = ["x86_64-linux" "aarch64-linux"];

      flake = let
        overlay = final: _prev: {
          flakehub-webhook-handler = final.callPackage ./packages/flakehub-webhook-handler {};
        };
      in {
        overlays.default = overlay;

        nixosModules = {
          default = {
            imports = [./modules];
            nixpkgs.overlays = [overlay];
          };
          flakehub-deploy = {
            imports = [./modules];
            nixpkgs.overlays = [overlay];
          };
        };
      };

      perSystem = {
        config,
        pkgs,
        ...
      }: {
        treefmt = {
          inherit (config.flake-root) projectRootFile;
          programs = {
            alejandra.enable = true;
            ruff-check.enable = true;
            ruff-format.enable = true;
            taplo.enable = true;
          };
        };

        packages = {
          flakehub-webhook-handler = pkgs.callPackage ./packages/flakehub-webhook-handler {};
        };
      };
    };
}
