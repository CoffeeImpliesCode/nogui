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
    # tracy_0_11
    mangohud
    zig-zlint
    ffmpeg
  ];

  env = {
    LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath packages}";
    INCLUDE_DIRECTORIES = "${pkgs.lib.makeIncludePath packages}";
    VULKAN_SDK = "${pkgs.vulkan-headers.out}";
    # zig-gate tuning (per AGENTS.md house rules): ziglint ignores + proto debt excluded
    ZIGLINT_ARGS = ""; # the tree is ziglint-clean (all codes, no ignores)
    GATE_EXCLUDE = "src/proto";
  };

  # https://devenv.sh/languages/
  # languages.zig.enable = true;

  scripts.gate.exec = "zig-gate";
}
