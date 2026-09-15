{ pkgs, lib, config, inputs, ... }:

let
  # Nixpkgs v0.5.3 does not classify merged public error sets as types.
  # Keep Z015 enabled and patch only that missing Zig 0.16 AST case.
  ziglintFixed = pkgs.ziglint.overrideAttrs (old: {
    patches = (old.patches or []) ++ [
      (pkgs.writeText "ziglint-z015-merged-error-sets.patch" ''
        --- a/src/Linter.zig
        +++ b/src/Linter.zig
        @@ -987,6 +987,9 @@ fn isTypeExpression(self: *Linter, node: Ast.Node.Index) bool {
                 // Error set declarations (e.g., error{A, B})
                 .error_set_decl => true,
        +        // Merged error sets (e.g., error{A} || Allocator.Error)
        +        // A public alias for one is a public type, too.
        +        .merge_error_sets => true,
                 // Function types
                 .fn_proto,
      '')
    ];
  });
in

rec {
  # https://devenv.sh/basics/
  env.GREET = "devenv";

  # https://devenv.sh/packages/
  packages = with pkgs; [
    # Zig 0.16 build and lint toolchain
    zig_0_16
    ziglintFixed
    zig-zlint
    pkg-config
    python3
    jujutsu
    # Lint source enumeration used by the build graph.
    findutils
    gnugrep
    vulkan-headers
    vulkan-loader
    vulkan-validation-layers
    # glslang
    shaderc
    shader-slang
    glslang
    # mesa
    wayland
    wayland-utils
    udev
    alsa-lib
    libdecor
    libusb1
    libxkbcommon
    xorg.libX11
    xorg.libXext
    xorg.libXi
    xorg.libxcb
    mangohud
    ffmpeg
    # Tracy 0.13.1 CLI tools (tracy-capture, tracy-csvexport)
    tracy
  ];

  env = {
    LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath packages}";
    INCLUDE_DIRECTORIES = "${pkgs.lib.makeIncludePath packages}";
    VULKAN_SDK = "${pkgs.vulkan-headers.out}";
  };

  # https://devenv.sh/languages/
  # languages.zig.enable = true;

  scripts.gate.exec = ''
    set -eu
    zig fmt --check src build.zig build.zig.zon
    zig build test check layout-check lint
    zig build test check -Doptimize=ReleaseSafe
    zig build --build-file vendor/noapi/build.zig test -Denable-tracy=false
    python3 -m unittest discover -s tools -p 'test_*.py'
  '';
}
