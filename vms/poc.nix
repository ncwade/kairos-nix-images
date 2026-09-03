{ pkgs, mkKairosImage }:

let
  name = "kairos-nix-poc";
  tag = "0.1.0";

  report = pkgs.writeShellApplication {
    name = "kairos-nix-report";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      install -d /run/kairos-nix
      jq -n \
        --arg status ready \
        --arg source nix \
        '{ status: $status, configurationSource: $source }' \
        > /run/kairos-nix/status.json
    '';
  };

  root = pkgs.runCommand "${name}-root" { } ''
    mkdir -p \
      $out/opt/kairos-nix/bin \
      $out/etc/systemd/system/multi-user.target.wants

    ln -s ${report}/bin/kairos-nix-report \
      $out/opt/kairos-nix/bin/kairos-nix-report

    cat > $out/etc/systemd/system/kairos-nix-poc.service <<'EOF'
    [Unit]
    Description=Prove that the Kairos VM customization came from Nix
    ConditionPathExists=/etc/kairos-release

    [Service]
    Type=oneshot
    ExecStart=/opt/kairos-nix/bin/kairos-nix-report
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    EOF

    ln -s ../kairos-nix-poc.service \
      $out/etc/systemd/system/multi-user.target.wants/kairos-nix-poc.service

    cat > $out/etc/kairos-nix-poc <<'EOF'
    This layer and its transitive package closure were built by Nix.
    EOF
  '';

  dockerArchive = mkKairosImage {
    inherit name tag root;
    base = {
      imageName = "quay.io/kairos/hadron";
      imageDigest = "sha256:ca75eb00118696ead63c689f92138da23c7231eb63c2903d7a7e7375ff5f7e83";
      sha256 = "sha256-qgR+TYyUox8ZBKqjLZ/ysHZNO2kxwHapkaQX4kttp2c=";
      finalImageName = "quay.io/kairos/hadron";
      finalImageTag = "v0.5.1-core-amd64-generic-v4.2.0";
    };
  };
in
{
  inherit
    name
    tag
    root
    dockerArchive
    ;
}
