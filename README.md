# Verus Flake

This repository packages [Verus](https://github.com/verus-lang/verus) as a
Nix flake. It provides both a buildable package and a development shell using
the Rust toolchain pinned by the upstream Verus source.

## Outputs

The flake currently exposes outputs for:

- `aarch64-linux`
- `x86_64-linux`
- `aarch64-darwin`

Quick run:

```sh
nix build github:pgattic/verus-flake
nix develop github:pgattic/verus-flake
```

The installed package provides:

- `verus`
- `cargo-verus`

Both wrappers set `VERUS_Z3_PATH` and disable runtime `rustup` use.

## Inputs

- `nixpkgs`: pinned from `nixos-unstable`
- `rust-overlay`: provides the exact Rust toolchain requested by Verus
- `verus-src`: the upstream Verus repository, used as a non-flake source

The Rust channel is read directly from:

```text
verus-src/rust-toolchain.toml
```

That keeps the flake from carrying a separate hand-maintained Rust version.

## Current Workarounds

This flake has a few intentional workarounds for the current Verus build:

- `flake-utils` is not used. The supported system list and `forAllSystems`
  helper are defined directly in `flake.nix`.
- Verus expects parts of the build to happen inside a Git repository. The Nix
  build phase initializes a temporary Git repository in the build directory and
  creates an empty local commit before building.
- Verus invokes `rustup show active-toolchain` from `build.rs`. Instead of
  depending on a real `rustup`, the flake provides a small fake `rustup` script
  that only answers that specific command.
- `VERUS_USE_RUSTUP=0` is set for the build, shell, and installed wrappers so
  Verus does not try to call `rustup` at runtime.
- `VERUS_Z3_PATH` is set explicitly so Verus uses the Z3 from nixpkgs.
- The default Rust package build phase is replaced. Verus is built in two
  steps: first the Verus tooling is built, then `cargo-verus` is used to build
  and verify `vstd`.
- Cargo is run with `--offline` during the Nix build so missing vendored
  dependencies fail inside the sandbox instead of trying to use the network.
- The full `source/target-verus/release` tree is installed under
  `$out/opt/verus`. The wrappers in `$out/bin` point into that tree because
  Verus resolves `vstd` artifacts relative to its executable.
- `doCheck = false` is set; the package build does not run an additional check
  phase after the Verus build steps.
- `auditable = false` is set so that Nix doesn't wrap Cargo with extra flags.

These are meant to keep the Nix build hermetic while matching the assumptions
in the upstream Verus build system.
