{ pkgs, lib, config, inputs, ... }:

rec {
  # https://devenv.sh/basics/
  env.GREET = "devenv";

  # https://devenv.sh/packages/
  packages = with pkgs; [
    # git
    vulkan-headers
    vulkan-loader
    vulkan-validation-layers
    # glslang
    shaderc
    shader-slang
    glslang
    # mesa
    wayland
    udev
    alsa-lib
    libdecor
    libusb1
    libxkbcommon
    xorg.libX11
    xorg.libXext
    xorg.libXi
    xorg.libxcb
    tracy_0_11
    mangohud
    zig-zlint
  ];

  env = {
    LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath packages}";
    INCLUDE_DIRECTORIES = "${pkgs.lib.makeIncludePath packages}";
    VULKAN_SDK = "${pkgs.vulkan-headers.out}";
  };

  # https://devenv.sh/languages/
  # languages.zig.enable = true;
}
