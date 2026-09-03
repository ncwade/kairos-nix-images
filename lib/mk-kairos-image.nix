{ pkgs }:

{
  name,
  tag,
  architecture,
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
    arch = architecture;
  };
in
pkgs.dockerTools.buildLayeredImage {
  inherit name tag;
  fromImage = baseImage;
  contents = [ root ];
  inherit architecture;
}
