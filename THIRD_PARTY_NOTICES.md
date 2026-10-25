# Third-party notices

The root MIT license covers first-party nogui code. The components below keep their own licenses.
Keep the linked license files with source and binary distributions that contain these components.

## noapi

- Paths: `vendor/noapi/`, including local changes.
- License: MIT for first-party noapi code, see `vendor/noapi/LICENSE`.
- Copyright (c) 2026 Janis Gertulla.
- Upstream URL: not recorded in the snapshot provenance.
- Snapshot: commit `5a6aec7c2b1b1dafea0e1bd686e4ccc041db75f4`, with changes recorded in `vendor/noapi-provenance.json`.
- Third-party bindings and snippets are listed below and in `vendor/noapi/THIRD_PARTY_NOTICES.md`.
- `vendor/noapi/shaders/sky.ppm` and `vendor/noapi/tools/gen_sky.py` are newly authored first-party MIT material, copyright 2026 Janis Gertulla.

### Khronos Vulkan XML API registry

- Path: `vendor/noapi/noapi/vk.zig` (generated Vulkan API bindings).
- License: `Apache-2.0 OR MIT`. This distribution uses the MIT option.
- Copyright 2015-2026 The Khronos Group Inc.
- Upstream: https://github.com/KhronosGroup/Vulkan-Headers
- The MIT permission text below applies.

### vulkan-zig generator templates

- Path: `vendor/noapi/noapi/vk.zig` (generated binding support code).
- License: MIT.
- Copyright © Robin Voetter.
- Upstream: https://github.com/Snektron/vulkan-zig
- The MIT permission text below applies.

### Inigo Quilez SDF and color snippets

- Paths: `vendor/noapi/shaders/sdf.slang`, `vendor/noapi/shaders/shader.slang`.
- License: MIT.
- Copyright (c) Inigo Quilez.
- Upstream: https://iquilezles.org/articles/distfunctions2d
- Technical snippet license: https://iquilezles.org/articles/
- The MIT permission text below applies.

## Taffy v0.13.0 fixtures

- Paths: `testdata/taffy-v0.13.0/upstream/test_fixtures/` and normalized fixture data under `testdata/taffy-v0.13.0/`.
- License: MIT.
- Copyright (c) 2018 Visly Inc.
- Copyright (c) 2026 Taffy Authors.
- Upstream: https://github.com/DioxusLabs/taffy
- Source commit: `45a56299d366ddb383e593a1f0372158d00e8530`.
- Import tool: `tools/import_taffy_v013_fixtures.py`.
- The MIT permission text below applies.

## AccessKit Rust crates

- Paths: `src/v7_host/accesskit_bridge/vendor/accesskit_atspi_common/` (0.20.0) and `src/v7_host/accesskit_bridge/vendor/accesskit_unix/` (0.23.0).
- License: `MIT OR Apache-2.0`.
- Authors and copyright holders: The AccessKit contributors, as identified by the upstream source notices.
- Upstream: https://github.com/AccessKit/accesskit
- Each crate retains its full `LICENSE-MIT` and `LICENSE-APACHE` files. Local patches do not replace these licenses.
- Each crate also retains `LICENSE.chromium`: BSD-3-Clause, Copyright 2015 The Chromium Authors. All rights reserved.
- Chromium upstream: https://chromium.googlesource.com/chromium/src/
- Other bridge dependencies are fetched by Cargo, not vendored here. Their versions are recorded in `src/v7_host/accesskit_bridge/Cargo.lock`.

## Inter

- Paths: `src/InterVariable.ttf`, `src/v7_text/InterVariable.ttf`, `src/v7_demo/InterVariable.ttf`.
- License: SIL Open Font License 1.1, full text in `src/Inter-LICENSE.txt`.
- Copyright (c) 2016 The Inter Project Authors.
- Upstream: https://github.com/rsms/inter

## DejaVu Sans

- Path: `src/DejaVuSans.ttf`.
- License: Bitstream Vera and Arev font terms, with DejaVu changes in the public domain.
- Copyright (c) 2003 by Bitstream, Inc. All Rights Reserved.
- Copyright (c) 2006 by Tavmjong Bah. All Rights Reserved.
- Full terms and additional font notices: `src/DejaVu-LICENSE.txt`.
- Upstream: https://dejavu-fonts.github.io/

## Fira Code Nerd Font

- Paths: `src/v7_text/FiraCodeNerdFont-Regular.ttf`, `src/v7_demo/FiraCodeNerdFont-Regular.ttf`.
- Font license: SIL Open Font License 1.1. The Nerd Fonts notice also contains MIT terms for its original source code.
- Copyright (c) 2014, The Fira Code Project Authors.
- Copyright (c) 2014 Ryan L McIntyre.
- Full license texts and upstream notices: `src/FiraCode-LICENSE.txt`, `src/NerdFonts-LICENSE.txt`.
- Upstreams: https://github.com/tonsky/FiraCode and https://github.com/ryanoasis/nerd-fonts

## MIT permission text

This text applies to each MIT component listed above, with its respective copyright notice.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
