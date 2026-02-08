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

      workflows.ci = {
        name = "CI";

        on = {
          push.branches = ["master"];
          pullRequest.branches = ["master"];
          workflowDispatch = {};
        };

        jobs.nix-ci = {
          uses = "DeterminateSystems/ci/.github/workflows/workflow.yml@main";
          permissions = {
            id-token = "write";
            contents = "read";
          };
          with_ = {
            visibility = "public";
          };
        };
      };
    };
  };
}
