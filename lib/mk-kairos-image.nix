{ pkgs }:

{
  name,
  tag,
  base,
  root,
}:

let
  baseImage = pkgs.dockerTools.pullImage {
    inherit (base)
      imageName
      imageDigest
      sha256
      finalImageName
      finalImageTag
      ;
    os = "linux";
    arch = "amd64";
  };
in
pkgs.dockerTools.buildLayeredImage {
  inherit name tag;
  fromImage = baseImage;
  contents = [ root ];
  architecture = "amd64";
}
