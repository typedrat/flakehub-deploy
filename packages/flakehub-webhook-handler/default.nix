{
  lib,
  python3Packages,
  systemd,
}:
python3Packages.buildPythonApplication {
  pname = "flakehub-webhook-handler";
  version = "0.1.0";

  src = ./.;

  pyproject = true;

  build-system = with python3Packages; [
    setuptools
  ];

  dependencies = with python3Packages; [
    fastapi
    uvicorn
    pydantic
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [systemd]}"
  ];

  # No tests yet
  doCheck = false;

  meta = {
    description = "GitHub webhook handler for FlakeHub deployments";
    mainProgram = "flakehub-webhook-handler";
    platforms = lib.platforms.linux;
  };
}
