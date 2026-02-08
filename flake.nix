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

        devShells.default = pkgs.mkShellNoCC {
          packages = [
            (pkgs.python3.withPackages (ps:
              with ps; [
                fastapi
                pydantic
                uvicorn
              ]))
          ];
        };

        packages = {
          flakehub-webhook-handler = pkgs.callPackage ./packages/flakehub-webhook-handler {};
        };
      };
    };
}
