# Nix-defined Kairos VM image POC

This repository demonstrates a practical boundary between Nix and
[Kairos](https://kairos.io/):

1. Nix pins an official Kairos OS image by registry digest.
2. Nix builds the desired software, filesystem additions, and systemd units.
3. Nix adds those outputs as a new image layer and emits an OCI archive.
4. Kairos/AuroraBoot turns that archive into a bootable VM disk. Once booted,
   Kairos can install and upgrade the machine from subsequent OCI versions.

An arbitrary NixOS container is not a Kairos image. Kairos expects a complete
bootable root filesystem containing its release metadata, agent, services,
kernel, and initrd. Starting from a pinned Kairos base preserves that contract
while still making the customization declarative and reproducible with Nix.

## What the POC adds

[`vms/poc.nix`](vms/poc.nix) is the VM image definition. It adds:

- a Nix-built program at `/opt/kairos-nix/bin/kairos-nix-report`, including its
  transitive `jq` closure under `/nix/store`;
- an enabled `kairos-nix-poc.service` systemd oneshot;
- a marker at `/etc/kairos-nix-poc`.

At boot the service writes `/run/kairos-nix/status.json`.

## Build and verify

The current POC targets x86-64/amd64.

```console
nix build
nix flake check
```

`result` is an OCI archive. The check inspects its config and layers and
verifies both sides of the contract: Kairos's release/kernel/initrd files
remain, and the Nix-built executable and enabled systemd service are present.

The lower-level Docker archive used by `dockerTools` is also available:

```console
nix build .#dockerArchive
```

## Produce a raw VM disk

AuroraBoot needs privileged loop/mount operations, so it cannot be a normal
sandboxed Nix derivation. The host also needs loop devices and vfat filesystem
support. The flake provides a Nix app that supplies Podman and runs AuroraBoot
against the locally built archive:

```console
nix run .#build-vm -- ./result ./output ./cloud-config.yaml
```

The app prompts for sudo because rootless containers cannot provide the loop
and mount capabilities AuroraBoot needs. It creates an EFI raw disk below
`./output`; files produced there may be root-owned. The AuroraBoot tool image
is digest-pinned. The app transparently converts the OCI archive to the Docker
archive layout expected by AuroraBoot's local-file loader. The cloud-config
argument is optional, but a reviewed config is needed when installing a real
machine.
[`cloud-config.yaml`](cloud-config.yaml) is only a template and its SSH key
placeholder must be replaced.

## Test the VM on macOS

Generate the raw disk on a Linux host as above, then copy the `.raw` file from
`./output` to the Mac. Raw disk generation cannot run directly on macOS because
AuroraBoot depends on Linux loop devices and filesystem mounts.

With [Nix installed](https://nixos.org/download/), boot the disk using the
flake-provided QEMU app:

```console
nix run .#test-vm -- /path/to/kairos.raw
```

The app supplies QEMU and UEFI firmware, opens the VM display, forwards host
port 2222 to the guest's SSH port, and uses QEMU snapshot mode so the source
disk is not modified. Set `KAIROS_SSH_PORT` to change the host port. Intel Macs
use Apple's HVF acceleration; Apple Silicon Macs emulate this POC's x86-64
image and will boot more slowly.

After replacing the key in `cloud-config.yaml` before disk creation, connect
with:

```console
ssh -p 2222 kairos@localhost
```

Then verify that the Nix-defined boot service ran:

```console
systemctl status kairos-nix-poc.service
cat /run/kairos-nix/status.json
```

For a registry-driven lifecycle, publish the archive explicitly (publishing is
not part of the Nix build):

```console
nix shell nixpkgs#skopeo -c \
  skopeo copy oci-archive:./result docker://registry.example.com/kairos/nix-poc:0.1.0
```

Then use that image reference as the install/upgrade source in Kairos. Increment
`tag` in `vms/poc.nix` for each immutable OS revision.

## Extending the POC

`lib.mkKairosImage` accepts a root derivation and image metadata. Add another
file under `vms/`, construct its root from Nix packages and configuration, and
call the same function. Do not overwrite Kairos-owned paths such as
`/etc/kairos-release`, `/boot/vmlinuz`, or `/boot/initrd`.
