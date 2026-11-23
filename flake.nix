{
  description = "nitpick.nvim's test suite, with its nvim and plenary from nixpkgs";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      forEachSystem =
        f:
        nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (
          system: f nixpkgs.legacyPackages.${system}
        );
      # What `make test` needs; tests/minimal_init.lua reads PLENARY_DIR.
      testEnv = pkgs: {
        packages = [
          pkgs.neovim-unwrapped
          pkgs.gnumake
          # branch_spec drives real git and jj repos.
          pkgs.git
          pkgs.jujutsu
        ];
        PLENARY_DIR = "${pkgs.vimPlugins.plenary-nvim}";
      };
    in
    {
      # `nix develop -c make test`
      devShells = forEachSystem (pkgs: {
        default = pkgs.mkShell (testEnv pkgs);
      });

      # `nix flake check`. comments_spec takes the cwd for a git checkout, as `make test` runs in one.
      checks = forEachSystem (pkgs: {
        test = pkgs.runCommand "nitpick-tests" (
          (testEnv pkgs) // { nativeBuildInputs = (testEnv pkgs).packages; }
        ) "cp -r ${self} src && chmod -R u+w src && cd src && git init -q && HOME=$TMPDIR make test && touch $out";
      });
    };
}
