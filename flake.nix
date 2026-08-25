{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      nameValuePair = name: value: { inherit name value; };
      genAttrs = names: f: builtins.listToAttrs (map (n: nameValuePair n (f n)) names);
      allSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forAllSystems =
        f:
        genAttrs allSystems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs {
              inherit system;
            };
          }
        );

      treefmtEval = forAllSystems ({ pkgs, ... }: treefmt-nix.lib.evalModule pkgs (import ./treefmt.nix));
    in
    {
      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            packages =
              with pkgs;
              (
                [
                  zig
                  qemu
                  python3
                ]
                ++ lib.optionals (stdenv.hostPlatform.isLinux) [
                  pkg-config
                  wayland
                ]
              );
          };
        }
      );

      formatter = forAllSystems ({ system, ... }: treefmtEval.${system}.config.build.wrapper);

      checks = forAllSystems (
        { system, pkgs, ... }:
        {
          default = pkgs.stdenv.mkDerivation (finalAttrs: {
            pname = "opendarwin";
            version = "0.1.0";

            src = lib.cleanSource ./.;

            zigDeps = pkgs.zig.fetchDeps {
              inherit (finalAttrs) src pname version;
              hash = "sha256-mV2H3bFJtsRHFLbk3Lu6ZbiInfGTe6Fv/7+5UZg2EW0=";
            };

            nativeBuildInputs =
              with pkgs;
              [
                zig
                python3
              ]
              ++ lib.optional (pkgs.stdenv.hostPlatform.isLinux) pkg-config;

            buildInputs = with pkgs; (lib.optional (pkgs.stdenv.hostPlatform.isLinux) wayland);

            postConfigure = ''
              ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
            '';
          });

          formatting = treefmtEval.${system}.config.build.check self;
        }
      );
    };
}
