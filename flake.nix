{
  description = "Verus Flake";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";
    rust-overlay.url = "github:oxalica/rust-overlay";
    verus-src = {
      url = "github:verus-lang/verus";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, rust-overlay, verus-src }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        builtins.listToAttrs (map (system: {
          name = system;
          value = f system;
        }) systems);

      perSystem = system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

        # Read straight out of the checked-out source so this can
        # never drift from whatever `verus-src` actually pins --
        # no hand-maintained version string to forget to update.
        toolchainToml = builtins.fromTOML
          (builtins.readFile "${verus-src}/rust-toolchain.toml");
        toolchainVersion = toolchainToml.toolchain.channel;
        toolchainTriple = "${toolchainVersion}-${pkgs.stdenv.hostPlatform.rust.rustcTargetSpec}";

        rustToolchain = pkgs.rust-bin.stable.${toolchainVersion}.minimal.override {
          extensions = [ "rustfmt" "rustc-dev" "llvm-tools" ];
        };

        rustPlatform = pkgs.makeRustPlatform {
          cargo = rustToolchain;
          rustc = rustToolchain;
        };

        # Verus's build.rs / main.rs shell out to `rustup` in a few
        # places. VERUS_USE_RUSTUP=0 disables the *runtime* call sites
        # in verus/src/main.rs, but verus/build.rs calls `rustup show
        # active-toolchain` unconditionally at build time with no env
        # var escape hatch -- so we stub it out instead of installing
        # a real rustup. Only needs to satisfy that one invocation;
        # anything else prints a clear error so it's easy to extend
        # if a future Verus version adds more call sites.
        fakeRustup = pkgs.writeShellScriptBin "rustup" ''
          if [ "$1" = "show" ] && [ "$2" = "active-toolchain" ]; then
            echo "${toolchainTriple} (env override)"
            exit 0
          fi
          echo "fake rustup: unsupported invocation: $@" >&2
          exit 1
        '';

        commonEnv = {
          VERUS_Z3_PATH = "${pkgs.z3}/bin/z3";
          VARGO_TOOLCHAIN = toolchainTriple;
          VERUS_USE_RUSTUP = "0";
        };

        commonNativeBuildInputs = [
          pkgs.python3
          pkgs.pkg-config
          pkgs.gitMinimal
          fakeRustup
        ];

        commonBuildInputs = [
          pkgs.z3
          pkgs.openssl
        ];
      in
      {
        devShells.default = pkgs.mkShell ({
          buildInputs = [ rustToolchain ] ++ commonBuildInputs ++ commonNativeBuildInputs;
        } // commonEnv);

        packages.default = rustPlatform.buildRustPackage ({
          pname = "verus";
          version = "unstable-${verus-src.shortRev or verus-src.rev or "dirty"}";
          src = verus-src;

          # The Cargo workspace lives in source/, not the repo root.
          cargoRoot = "source";
          cargoLock = {
            lockFile = "${verus-src}/source/Cargo.lock";
            outputHashes = {
              "getopts-0.2.21" = "sha256-N/QJvyOmLoU5TabrXi8i0a5s23ldeupmBUzP8waVOiU=";
            };
          };

          nativeBuildInputs = commonNativeBuildInputs ++ [ pkgs.makeWrapper ];
          buildInputs = commonBuildInputs;

          # Skip the default single `cargo build` phase: Verus builds
          # in two steps -- build the rust_verify/verus tooling, then
          # use the freshly-built cargo-verus to build+verify vstd
          # against it. --offline matters here: the sandbox has no
          # network at all, unlike an interactive `nix develop` shell,
          # so incomplete vendoring will surface here if it exists.
          buildPhase = ''
            runHook preBuild
            git init -q .
            git config user.email "nix@build.local"
            git config user.name "nix"
            git add -A
            git commit -q -m "nix build" --allow-empty

            cd source
            cargo build --release --offline
            cargo run --release --offline -p cargo-verus -- \
              build --release --manifest-path vstd/Cargo.toml
            cd ..
            runHook postBuild
          '';

          # Keep the whole target-verus/release tree intact instead of
          # splitting into bin/lib -- `verus` resolves vstd's .vir and
          # .rlib artifacts relative to its own binary path.
          installPhase = ''
            runHook preInstall
            mkdir -p $out/opt/verus
            cp -r source/target-verus/release/. $out/opt/verus/
            mkdir -p $out/bin
            makeWrapper $out/opt/verus/verus $out/bin/verus \
              --set VERUS_Z3_PATH "${pkgs.z3}/bin/z3" \
              --set VERUS_USE_RUSTUP "0"
            makeWrapper $out/opt/verus/cargo-verus $out/bin/cargo-verus \
              --set VERUS_Z3_PATH "${pkgs.z3}/bin/z3" \
              --set VERUS_USE_RUSTUP "0"
            runHook postInstall
          '';

          doCheck = false;
          auditable = false;
        } // commonEnv);
      };
    in
    {
      devShells = forAllSystems (system: (perSystem system).devShells);
      packages = forAllSystems (system: (perSystem system).packages);
    };
}
