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

  # The nested private compositor has no DRM render device. Upstream 0.8.4
  # passes NULL to its GBM constructor, then offers unusable DMA-BUF formats.
  # Keep the real provider's shared-memory capture path available instead.
  xdgPortalWlrFixed = pkgs.xdg-desktop-portal-wlr.overrideAttrs (old: {
    patches = (old.patches or []) ++ [
      (pkgs.writeText "xdg-desktop-portal-wlr-optional-gbm.patch" ''
        --- a/src/screencast/screencast_common.c
        +++ b/src/screencast/screencast_common.c
        @@ -25,6 +25,10 @@
         struct gbm_device *xdpw_gbm_device_create(drmDevice *device) {
        +	if (!device) {
        +		logprint(DEBUG, "xdpw: No DRM device; using shared-memory buffers");
        +		return NULL;
        +	}
         	if (!(device->available_nodes & (1 << DRM_NODE_RENDER))) {
         		logprint(ERROR, "xdpw: DRM device has no render node");
         		return NULL;
         	}
         
        --- a/src/screencast/pipewire_screencast.c
        +++ b/src/screencast/pipewire_screencast.c
        @@ -155,7 +155,7 @@
         static void build_formats(struct spa_pod_builder *builder, struct xdpw_screencast_instance *cast,
         		struct wl_array *params) {
        -	if (!cast->avoid_dmabufs) {
        +	if (!cast->avoid_dmabufs && cast->ctx->gbm) {
         		uint32_t last_format = DRM_FORMAT_INVALID;
         		struct xdpw_format_modifier_pair *fm_pair;
         		wl_array_for_each(fm_pair, &cast->current_constraints.dmabuf_format_modifier_pairs) {
         			if (last_format == fm_pair->fourcc) {
      '')
    ];
  });

  # speech-dispatcher 0.12.1 with the native module-carrier patches, declared as
  # one override of the pinned package rather than installed or copied. The
  # upstream derivation's own three patches are preserved in their own order,
  # and the two repository patches are appended AFTER them, in this order:
  #
  #   1. speech-dispatcher-write-all.patch      the module write itself: loop
  #      the remaining bytes, retry EINTR, turn a zero-length write into EIO,
  #      and preserve the prefix that really went out. It changes no global
  #      helper and no module or public ABI.
  #   2. speech-dispatcher-module-metadata.patch the sideband record of that
  #      write: the physical pipe identity, the daemon and proxy births, the
  #      stream epoch, the actual written offset range and the daemon's own
  #      message id. Its hunks are written against the tree patch 1 produces,
  #      which is why the order is fixed and why it must not be hoisted above.
  #
  # ORDER IS LOAD-BEARING AND THE PATCH FILES ARE OWNED ELSEWHERE: they are
  # authored against the exact upstream 0.12.1 tarball
  # (speech-dispatcher-0.12.1.tar.gz), not against this file. If either path
  # below is missing, this evaluation is expected to fail loudly rather than
  # silently fall back to a stock daemon.
  #
  # Nothing here patches a module, a client or the audio plugins: the module
  # bytes, the stock python binding and the audio closure are exactly what
  # upstream 0.12.1 ships, and only the daemon side changes.
  speechdNativeCarrier = pkgs.speechd.overrideAttrs (old: {
    patches = (old.patches or []) ++ [
      ./tools/patches/speech-dispatcher-write-all.patch
      ./tools/patches/speech-dispatcher-module-metadata.patch
    ];
  });

  # The private capture compositor's own dlopen runtime, declared here and
  # nowhere else. niri creates its event loop through winit's x11-dl, which
  # opens bare SONAMEs (libXcursor.so.1 and its siblings) before it has read a
  # single line of config, and a store build's RUNPATH does not carry those
  # objects. The W20 fixture builds every child from an environment ALLOWLIST
  # that deliberately carries no LD_LIBRARY_PATH, so the operator's session
  # value cannot reach the compositor either; the compositor needs a declared
  # one instead. This list is that declaration: exactly the compositor's own
  # runtime, exported below as one value the fixture validates and hands to
  # niri alone. Nothing else in the run receives it.
  privateCompositorRuntime = with pkgs; [
    niri
    xorg.libX11
    xorg.libXcursor
    xorg.libXext
    xorg.libXi
    xorg.libXrandr
    xorg.libXinerama
    libxkbcommon
    wayland
  ];

  # The transparent speech-module observer, packaged from this repository's own
  # source rather than installed into the session. speech-dispatcher execs an
  # output module with a fixed argv[0] and argv[1] and nothing else, so the
  # observer cannot take a flag on a command line; it needs a real executable
  # path, and this is where that path comes from. The interpreter is pinned
  # into the shebang so the store build never depends on PATH, and the file is
  # the one in ./tools, so there is no second copy of it anywhere.
  speechModuleObserver = pkgs.runCommand "nogui-speech-module-observer"
    {
      src = ./tools/speech_module_observer.py;
      interpreter = "${pkgs.python3}/bin/python3";
    }
    ''
      install -Dm755 "$src" "$out/bin/nogui-speech-module-observer"
      substituteInPlace "$out/bin/nogui-speech-module-observer" \
        --replace-fail '#!/usr/bin/env python3' '#!'"$interpreter"
    '';
in

rec {
  # https://devenv.sh/basics/
  env.GREET = "devenv";

  # https://devenv.sh/packages/
  packages = with pkgs; [
    ziglintFixed
    zig-zlint
    pkg-config
    (python3.withPackages (python: [
      python.pygobject3
      python.pyatspi
      python.dasbus
      python.pycairo
      python.dbus-python
    ]))
    # Optional owned AccessKit C-ABI bridge.
    cargo
    rustc
    # CPU text bidi and Unicode grapheme boundaries.
    fribidi
    utf8proc
    # Native SVG and JPEG image decoding in the optional host.
    librsvg
    cairo
    glib
    # Real AT-SPI and speech providers for approved isolated native acceptance.
    at-spi2-core
    orca
    speechd
    espeak-ng
    pulseaudio
    dconf
    gnome-desktop
    gsettings-desktop-schemas
    # The stock terminal wrapper the approved W21 run puts the screen reader
    # inside. util-linux `script` is what gives that reader a real controlling
    # terminal, which is what its own debug stream is written to; nothing else
    # in this list can hand a process a controlling terminal, and the run
    # installs nothing at run time. Declared, never searched for on PATH.
    util-linux
    libjpeg_turbo
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
    # Owned headless compositor input fixture and its protocol headers.
    wayland-scanner
    wlr-protocols
    wayland-utils
    # ScreenCast stream transport and its authoritative SPA/PipeWire headers.
    pipewire
    udev
    alsa-lib
    libdecor
    libusb1
    libxkbcommon
    xorg.libX11
    xorg.libXcursor
    xorg.libXext
    xorg.libXi
    xorg.libxcb
    # Isolated native acceptance; never drive the user's desktop session.
    xorg.xorgserver
    xorg.setxkbmap
    xorg.xwininfo
    xorg.xprop
    openbox
    niri
    # Private compositor without layer-shell for the real unavailable gate.
    weston
    # Owned headless outputs for real layer close/removal; no session wrapper.
    (sway-unwrapped.overrideAttrs (_: {
      enableXWayland = false;
      trayEnabled = false;
    }))
    grim
    imagemagick
    ibus
    ibus-engines.libpinyin
    dbus
    dunst
    gnome-keyring
    # The real Secret Service UI agent. gnome-keyring implements its prompts
    # through libgcr-base, which asks the well-known name
    # org.gnome.keyring.SystemPrompter to show the dialog, and that program is
    # gcr-prompter in this package. gnome-keyring already builds against gcr;
    # declaring it here is what gives the prompter a source, and nothing is
    # ever installed to satisfy a prompt at run time.
    gcr
    xdg-desktop-portal
    xdg-desktop-portal-gtk
    # Private ScreenCast provider and its mandatory interactive output chooser.
    xdgPortalWlrFixed
    slurp
    xclip
    wl-clipboard
    # Owned private viewer route for the ScreenCast acceptance: x11vnc serves the
    # private Xvfb on loopback only, and TigerVNC supplies the declared viewer
    # (vncviewer) and the real password-file maker (vncpasswd). Declared, not
    # installed at run time; no viewer is ever launched by a test.
    x11vnc
    tigervnc
    xdotool
    mangohud
    ffmpeg
    # Tracy 0.13.1 CLI tools (tracy-capture, tracy-csvexport)
    tracy
    # The speech-dispatcher module observer: the executable the private W21
    # run hands the daemon as its AddModule binary, so the bytes crossing the
    # daemon/module pipe are captured. Declared here, never installed by the
    # fixture.
    speechModuleObserver

    # The patched speech-dispatcher whose daemon carries the native module
    # carrier. Declared, never installed imperatively, and never resolved from
    # PATH: the fixture and the controller both read the one env name below and
    # take no fallback, so the provider they ran is the one declared here. The
    # stock `speechd` above stays in this list on purpose: its module binaries,
    # its config tree and its python binding are the genuine module and the
    # genuine stock client this run must use untouched. Nothing in this list is
    # ever searched for by name at run time.
    speechdNativeCarrier
  ];

  env = {
    # Zig flocks every global-cache manifest. A build that dies holding one
    # of its manifest locks wedges every later build that wants the same
    # global cache. A project-local global cache keeps `zig build`
    # independent of that; the cost is one extra compiler_rt build.
    ZIG_GLOBAL_CACHE_DIR = ".zig-global-cache";

    # The declared executable path of the speech-module observer above. The
    # private W21 fixture reads this one name and takes NO PATH fallback: a
    # host `nogui-speech-module-observer` must never stand in for the declared
    # one, so the gate and the run cannot disagree about which binary this is.
    # Nothing is ever installed to satisfy it.
    NOGUI_MODULE_OBSERVER = "${speechModuleObserver}/bin/nogui-speech-module-observer";

    # The declared executable path of the patched speech-dispatcher above, and
    # the ONLY name that selects the speech provider for a run. It is a store
    # path to one file, not a directory, so a run that resolves it has resolved
    # the provider and can derive that same closure's module dir, config dir,
    # audio plugin dir and python site-packages from its own prefix. There is no
    # PATH fallback: a run that cannot read this name starts nothing, which is
    # what keeps an ambient `speech-dispatcher` from ever standing in for the
    # patched one.
    NOGUI_SPEECH_DISPATCHER = "${speechdNativeCarrier}/bin/speech-dispatcher";

    # The exact prompter the declared gcr output above ships. This is
    # libexec/gcr-prompter, the binary wrapper the package's own two activation
    # entries (org.gnome.keyring.SystemPrompter.service and
    # org.gnome.keyring.PrivatePrompter.service) both Exec, so it is the one
    # path a run may name and resolve for this role. The wrapper prepends gcr's
    # own GSettings, GI and share directories to whatever XDG_DATA_DIRS it is
    # given, so a private run keeps its own owned data directory and never
    # gains /usr/local/share or /usr/share.
    NOGUI_GCR_PROMPTER = "${pkgs.gcr}/libexec/gcr-prompter";

    # The compositor-only dlopen runtime, from the declared list above. devenv
    # emits every env value as one single-quoted literal, so this is exactly
    # that list and never a prefix on whatever the operator's session already
    # had. The fixture reads this one name, refuses a value that is not a real
    # /nix/store library directory, pins every directory it accepts, and gives
    # the joined list to niri and to no other child.
    NOGUI_PRIVATE_COMPOSITOR_LD_LIBRARY_PATH = lib.makeLibraryPath privateCompositorRuntime;
    LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath packages}";
    INCLUDE_DIRECTORIES = "${pkgs.lib.makeIncludePath packages}";
    VULKAN_SDK = "${pkgs.vulkan-headers.out}";
    AT_SPI_BUS_LAUNCHER = "${pkgs.at-spi2-core}/libexec/at-spi-bus-launcher";
    AT_SPI2_REGISTRYD = "${pkgs.at-spi2-core}/libexec/at-spi2-registryd";
    AT_SPI_DATADIR = "${pkgs.at-spi2-core}/share";
    # The declared terminal wrapper, by path and not by name. The W21 run reads
    # this one name and takes no fallback: a host `script` must never stand in
    # for the declared one, so the gate and the run can never disagree about
    # which binary gave the reader its controlling terminal.
    NOGUI_SCRIPT = "${pkgs.util-linux}/bin/script";
    GI_TYPELIB_PATH = pkgs.lib.concatStringsSep ":" [
      "${pkgs.at-spi2-core}/lib/girepository-1.0"
      "${pkgs.gobject-introspection}/lib/girepository-1.0"
      "${pkgs.glib}/lib/girepository-1.0"
    ];
  };

  enterShell = ''
    if [ "$(zig version)" != "0.17.0" ]; then
      echo "nogui requires Zig 0.17.0 on PATH" >&2
      return 1
    fi
  '';

  # https://devenv.sh/languages/
  # languages.zig.enable = true;

  scripts.gate.exec = ''
    set -eu
    zig fmt --check src build.zig build.zig.zon
    zig build test check layout-check lint
    zig build test check -Doptimize=safe
    zig build --build-file vendor/noapi/build.zig test -Denable-tracy=false
    python3 -m unittest discover -s tools -p 'test_*.py'
  '';
}
