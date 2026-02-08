{
  description = "Development inputs for flakehub-deploy. These are used by the top level flake in the dev partition, but do not appear in consumers' lock files.";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";

    flake-root.url = "github:srid/flake-root";

    files.url = "github:mightyiam/files";

    github-actions-nix.url = "https://flakehub.com/f/synapdeck/github-actions-nix/*";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # This flake is only used for its inputs
  outputs = _: {};
}
