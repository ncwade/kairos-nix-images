{
  description = "Nix-defined Kairos VM images";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      supportedSystems = [
        system
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      pkgs = import nixpkgs { inherit system; };
      mkKairosImage = import ./lib/mk-kairos-image.nix { inherit pkgs; };
      vm = import ./vms/poc.nix { inherit pkgs mkKairosImage; };

      ociArchive =
        pkgs.runCommand "${vm.name}-${vm.tag}.oci.tar"
          {
            nativeBuildInputs = [ pkgs.skopeo ];
          }
          ''
            export TMPDIR=$PWD/tmp
            mkdir "$TMPDIR"
            skopeo --tmpdir "$TMPDIR" --insecure-policy copy \
              docker-archive:${vm.dockerArchive} \
              oci-archive:$out:${vm.tag}
          '';

      verifyImage =
        pkgs.runCommand "verify-${vm.name}-${vm.tag}"
          {
            nativeBuildInputs = [ pkgs.jq ];
          }
          ''
            mkdir archive
            tar -xf ${ociArchive} -C archive

            manifest_digest=$(jq -r '.manifests[0].digest' archive/index.json)
            manifest="archive/blobs/sha256/''${manifest_digest#sha256:}"
            config_digest=$(jq -r '.config.digest' "$manifest")
            config="archive/blobs/sha256/''${config_digest#sha256:}"
            jq -e '.architecture == "amd64" and .os == "linux"' "$config" >/dev/null

            : > files
            : > service
            while read -r layer_digest; do
              layer="archive/blobs/sha256/''${layer_digest#sha256:}"
              tar -tf "$layer" 2>/dev/null | sed -e 's#^\./##' -e 's#^/##' >> files
              service_member=$(tar -tf "$layer" 2>/dev/null \
                | grep -E '^(/|\./)?nix/store/[^/]+-kairos-nix-poc-root/etc/systemd/system/kairos-nix-poc\.service$' \
                || true)
              if [[ -n "$service_member" ]]; then
                tar -xOf "$layer" "$service_member" 2>/dev/null > service
              fi
            done < <(jq -r '.layers[].digest' "$manifest")

            grep -qx 'etc/kairos-release' files
            grep -qx 'boot/vmlinuz' files
            grep -qx 'boot/initrd' files
            grep -qx 'opt/kairos-nix/bin/kairos-nix-report' files
            grep -qx \
              'etc/systemd/system/multi-user.target.wants/kairos-nix-poc.service' \
              files
            grep -q '^ExecStart=/opt/kairos-nix/bin/kairos-nix-report$' \
              service

            touch $out
          '';

      buildVm = pkgs.writeShellApplication {
        name = "build-kairos-vm";
        runtimeInputs = [
          pkgs.podman
          pkgs.skopeo
        ];
        text = ''
          if [[ $# -lt 1 || $# -gt 3 ]]; then
            echo "usage: build-kairos-vm OCI-ARCHIVE [OUTPUT-DIRECTORY] [CLOUD-CONFIG]" >&2
            exit 2
          fi

          if (( EUID != 0 )); then
            exec sudo -- "$0" "$@"
          fi

          archive=$(realpath "$1")
          output=$(realpath -m "''${2:-./output}")
          mkdir -p "$output"

          work=$(mktemp -d)
          trap 'rm -rf "$work"' EXIT
          mkdir "$work/skopeo"
          docker_archive="$work/kairos-nix-poc.tar"
          skopeo --tmpdir "$work/skopeo" --insecure-policy copy \
            "oci-archive:$archive" \
            "docker-archive:$docker_archive:kairos-nix-poc:${vm.tag}"

          volumes=(
            -v "$docker_archive:/images/kairos-nix-poc.tar:ro"
            -v "$output:/output"
          )
          arguments=(
            --set container_image=ocifile:///images/kairos-nix-poc.tar
            --set state_dir=/output
            --set disable_http_server=true
            --set disable_netboot=true
            --set disk.efi=true
          )

          if [[ $# == 3 ]]; then
            cloud_config=$(realpath "$3")
            volumes+=(-v "$cloud_config:/config.yaml:ro")
            arguments+=(--cloud-config /config.yaml)
          fi

          image=quay.io/kairos/auroraboot@sha256:784509bb3d01c2995cf427ca2ea7ab8292860477fecf462388b86745ed02da5c
          policy="$work/policy.json"
          printf '{"default":[{"type":"insecureAcceptAnything"}]}' > "$policy"
          podman pull --signature-policy "$policy" "$image"

          podman run --rm --privileged --pull=never \
            "''${volumes[@]}" \
            "$image" \
            "''${arguments[@]}"
        '';
      };

      mkTestVm =
        hostPkgs:
        hostPkgs.writeShellApplication {
          name = "test-kairos-vm";
          runtimeInputs = [ hostPkgs.qemu ];
          text = ''
            if [[ $# != 1 ]]; then
              echo "usage: test-kairos-vm RAW-DISK" >&2
              exit 2
            fi

            if [[ ! -f "$1" ]]; then
              echo "raw disk not found: $1" >&2
              exit 1
            fi
            disk=$(realpath "$1")

            case "$(uname -s):$(uname -m)" in
              Darwin:x86_64)
                acceleration=(-accel hvf -cpu host)
                ;;
              Linux:x86_64)
                if [[ -r /dev/kvm && -w /dev/kvm ]]; then
                  acceleration=(-accel kvm -cpu host)
                else
                  acceleration=(-accel "tcg,thread=multi" -cpu max)
                fi
                ;;
              *)
                echo "Using x86 emulation; booting can be slow on Apple Silicon." >&2
                acceleration=(-accel "tcg,thread=multi" -cpu max)
                ;;
            esac

            firmware=$(mktemp -d)
            trap 'rm -rf "$firmware"' EXIT
            cp ${hostPkgs.OVMF.fd}/FV/OVMF_VARS.fd "$firmware/OVMF_VARS.fd"

            qemu-system-x86_64 \
              -machine q35 \
              "''${acceleration[@]}" \
              -m 4096 \
              -smp 4 \
              -drive if=pflash,format=raw,readonly=on,file=${hostPkgs.OVMF.fd}/FV/OVMF_CODE.fd \
              -drive if=pflash,format=raw,file="$firmware/OVMF_VARS.fd" \
              -drive if=virtio,format=raw,snapshot=on,file="$disk" \
              -nic "user,model=virtio-net-pci,hostfwd=tcp::''${KAIROS_SSH_PORT:-2222}-:22"
          '';
        };

      testApps = nixpkgs.lib.genAttrs supportedSystems (
        hostSystem:
        let
          testVm = mkTestVm (import nixpkgs { system = hostSystem; });
        in
        {
          test-vm = {
            type = "app";
            program = "${testVm}/bin/test-kairos-vm";
            meta.description = "Boot a Kairos raw disk in an ephemeral QEMU VM";
          };
        }
      );
    in
    {
      lib.mkKairosImage = mkKairosImage;

      packages.${system} = {
        default = ociArchive;
        ociArchive = ociArchive;
        dockerArchive = vm.dockerArchive;
        vmRoot = vm.root;
      };

      apps = testApps // {
        ${system} = testApps.${system} // {
          build-vm = {
            type = "app";
            program = "${buildVm}/bin/build-kairos-vm";
            meta.description = "Build an EFI Kairos VM disk from the Nix-built OCI archive";
          };
        };
      };

      checks.${system}.image-contract = verifyImage;

      formatter = nixpkgs.lib.genAttrs supportedSystems (
        hostSystem: (import nixpkgs { system = hostSystem; }).nixfmt-tree
      );
    };
}
