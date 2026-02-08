{inputs, ...}: {
  imports = [
    inputs.flake-root.flakeModule
    inputs.files.flakeModules.default
    inputs.github-actions-nix.flakeModules.default
    inputs.treefmt-nix.flakeModule
  ];

  perSystem = {
    config,
    lib,
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
            httpx
            pydantic
            uvicorn
          ]))
      ];
    };

    # Sync generated workflows to .github/workflows/
    files.files =
      lib.mapAttrsToList (name: drv: {
        path_ = ".github/workflows/${name}";
        inherit drv;
      })
      config.githubActions.workflowFiles;

    # Expose the files writer as an app
    apps.write-files = {
      type = "app";
      program = lib.getExe config.files.writer.drv;
    };

    githubActions = {
      enable = true;

      workflows.build = {
        name = "Build and Publish";

        on = {
          push.branches = ["master"];
          pullRequest.branches = ["master"];
          workflowDispatch = {};
        };

        jobs = {
          build = {
            name = "Build packages";
            runsOn = "ubuntu-latest";

            permissions = {
              id-token = "write";
              contents = "read";
            };

            steps = [
              {uses = "actions/checkout@v4";}
              {uses = "DeterminateSystems/determinate-nix-action@v3";}
              {uses = "DeterminateSystems/flakehub-cache-action@main";}
              {uses = "DeterminateSystems/flake-checker-action@main";}
              {
                name = "Check flake";
                run = "nix flake check";
              }
              {
                name = "Build packages";
                run = ''
                  nix build .#flakehub-deploy-runner
                  nix build .#flakehub-webhook-handler
                '';
              }
            ];
          };

          publish = {
            name = "Publish to FlakeHub";
            runsOn = "ubuntu-latest";
            needs = "build";
            if_ = "github.ref == 'refs/heads/master' && needs.build.result == 'success'";

            permissions = {
              id-token = "write";
              contents = "read";
            };

            steps = [
              {uses = "actions/checkout@v4";}
              {uses = "DeterminateSystems/determinate-nix-action@v3";}
              {
                uses = "DeterminateSystems/flakehub-push@main";
                with_ = {
                  visibility = "public";
                  rolling = true;
                  rolling-minor = "0.1";
                };
              }
            ];
          };
        };
      };
    };
  };
}
