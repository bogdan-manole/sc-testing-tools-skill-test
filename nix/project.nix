{ inputs, pkgs, lib }:

let
  cabalProject = pkgs.haskell-nix.cabalProject' (

    { config, pkgs, ... }:

    {
      name = "vesting";

      compiler-nix-name = lib.mkDefault "ghc966";

      src = lib.cleanSource ../.;

      flake.variants = {
        ghc966 = { };
      };

      inputMap = { "https://chap.intersectmbo.org/" = inputs.CHaP; };

      cabalProjectLocal = "";

      modules = [ ];
    }
  );

in

cabalProject
