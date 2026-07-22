{
  description = ''
    multilevel — a locked-down NixOS host running N isolated KVM environments
    side by side, switchable with a single keystroke. NixOS port of the
    Alpine/bash appliance (host-only: guests stay as cloud-init cloud images).
  '';

  inputs = {
    # Pin to a released stable channel for an appliance. Bump deliberately;
    # `nixos-rebuild` rollback + generations are the whole point of the port.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    # Produces the bootable image reproducibly (replaces build/make-image.sh +
    # the privileged-Docker/Alpine build).
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, nixos-generators }:
    let
      # The appliance itself is always x86_64 (KVM target). Dev tooling also
      # runs on the maintainer's Mac, so the devShell is exposed on Darwin too.
      applianceSystem = "x86_64-linux";
      devSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllDev = f: nixpkgs.lib.genAttrs devSystems (system: f system);

      # Modules that make up the appliance, minus the per-machine config.
      applianceModules = [
        ./nix/modules/appliance
        ./nix/hosts/appliance/configuration.nix
      ];
    in
    {
      # --- The system definition ---------------------------------------------
      # Build/switch with: nixos-rebuild switch --flake .#appliance
      nixosConfigurations.appliance = nixpkgs.lib.nixosSystem {
        system = applianceSystem;
        modules = applianceModules;
      };

      # --- The bootable, self-installing image -------------------------------
      # nix build .#image  ->  a raw EFI disk image you flash to USB.
      # On Apple Silicon this cross-builds x86_64: point Nix at a Linux builder
      # (nix-darwin's `linux-builder`, or a remote builder) — see README-nixos.md.
      packages = forAllDev (system:
        nixpkgs.lib.optionalAttrs (system == applianceSystem) {
          image = nixos-generators.nixosGenerate {
            inherit system;
            format = "raw-efi";
            modules = applianceModules;
          };
          # An installer ISO variant (boot it to install onto the internal disk),
          # closer to the current USB-boots-and-installs UX.
          installer-iso = nixos-generators.nixosGenerate {
            inherit system;
            format = "install-iso";
            modules = applianceModules;
          };
        });

      # --- CI: the isolation guarantee, verified in a VM test ----------------
      # nix flake check  ->  boots the appliance in QEMU and asserts that no
      # environment can reach another (the crown-jewel guarantee), in CI, with
      # no hardware. This is stronger than the on-hardware isolate.sh checks.
      checks.${applianceSystem}.isolation =
        import ./tests/isolation.nix {
          pkgs = nixpkgs.legacyPackages.${applianceSystem};
          inherit self;
        };

      # --- Dev shell: same lint gates as the bash branch, plus Nix tooling ---
      devShells = forAllDev (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nixpkgs-fmt
              statix
              deadnix
              shellcheck # still lints any embedded shell (i3/keyd/first-boot)
            ];
          };
        });

      # `nix fmt` formats the tree.
      formatter = forAllDev (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
