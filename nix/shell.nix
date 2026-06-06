{ inputs, pkgs, lib, project, utils, ghc, system }:

let

  allTools = {
    "ghc966".cabal = project.projectVariants.ghc966.tool "cabal" "latest";
    "ghc966".cabal-fmt = project.projectVariants.ghc966.tool "cabal-fmt" "latest";
    "ghc966".haskell-language-server = project.projectVariants.ghc966.tool "haskell-language-server" "latest";
    "ghc966".fourmolu = project.projectVariants.ghc966.tool "fourmolu" "latest";
    "ghc966".hlint = project.projectVariants.ghc966.tool "hlint" "latest";
  };

  tools = allTools.${ghc};

  preCommitCheck = inputs.pre-commit-hooks.lib.${pkgs.system}.run {
    src = lib.cleanSources ../.;
    hooks = {
      cabal-fmt = {
        enable = true;
        package = tools.cabal-fmt;
      };
      fourmolu = {
        enable = true;
        package = tools.fourmolu;
        args = [ ];
      };
    };
  };

  commonPkgs = [
    tools.haskell-language-server
    tools.fourmolu
    tools.cabal
    tools.hlint
    tools.cabal-fmt

    pkgs.nixpkgs-fmt
    pkgs.bash
    pkgs.git
    pkgs.which
    pkgs.cacert
    pkgs.curl
    pkgs.zlib
  ];

  shell = project.shellFor {
    name = "vesting-${project.args.compiler-nix-name}";

    buildInputs = commonPkgs;

    withHoogle = true;

    shellHook = ''
      ${preCommitCheck.shellHook}
      export PS1="\n\[\033[1;32m\][vesting-shell:\w]\$\[\033[0m\] "
    '';
  };

in

shell
