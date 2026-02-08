{
  lib,
  python3Packages,
  fh,
  nixos-rebuild,
}:
python3Packages.buildPythonApplication {
  pname = "flakehub-deploy-runner";
  version = "0.1.0";

  src = ./.;

  pyproject = true;

  build-system = with python3Packages; [
    setuptools
  ];

  dependencies = with python3Packages; [
    httpx
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [fh nixos-rebuild]}"
  ];

  # No tests yet
  doCheck = false;

  meta = {
    description = "FlakeHub deployment runner with Discord notifications";
    mainProgram = "flakehub-deploy-runner";
    platforms = lib.platforms.linux;
  };
}
