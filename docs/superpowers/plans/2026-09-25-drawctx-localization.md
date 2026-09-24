# DrawCtx Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven development or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status (2026-09-30): planned, not implemented.** No localization code exists in this repository. A case-insensitive search of `src` for `localiz`, `catalog`, `message_key`, `LocalizedText`, `slug` and `tr(` returns no matches. Every declaration below is a **target signature**, not code that exists today.

**Goal:** Let a component supply a stable message slug and typed arguments during `DrawCtx.draw`, then use translated, formatted text in every text-bearing widget: label, button, slider, checkbox, switch, radio, and progress.

**Architecture:** Compile and validate an immutable, application-supplied catalog before drawing. `App` borrows that catalog, selects a locale, and owns two fixed-capacity text slabs indexed with its two frame arenas. `DrawCtx.tr` resolves one message into the current slab. Text widgets adopt that frame-owned result without duplicating it. The slug stays machine identity for content; the resolved phrase supplies visual and accessibility names. The formatter depends on no widget, host or GPU type.

**Tech stack:** Zig 0.16; canonical `src/v7/` library; `src/v7_text/` for shaping; existing SDL3/FreeType/HarfBuzz demo and noapi renderer. Localization adds no GPU dependency, no second rendering path, no second shape cache and no second accessibility tree.

**Product scope:** this is a separate feature plan. It is not part of GPUI API parity completion. The parity plan states that GPUI does not supply a built-in catalog localization system, and this plan's product goal survives reconciliation unchanged.

## Reconciliation contract — the five infrastructure rules

These five rules are **authoritative**. They come from [the parity plan's localization reconciliation](2026-09-26-gpui-api-parity.md#localization-plan) and supersede any conflicting infrastructure instruction in this document. Where a later section or task contradicts a rule, the rule wins and the task is wrong.

**R1 — Immutable catalog, typed arguments, per-App slabs, zero-copy adoption.**
Keep immutable catalogs, typed arguments, explicit locale selection, a fixed two-slab frame budget, and zero-copy adoption into all seven text-bearing widgets. *Supersedes:* any step that mutates an installed catalog, allocates formatted text, or copies a resolved translation into frame storage.
*Current anchor:* `App.arenas: [2]std.heap.ArenaAllocator` (`src/v7/app.zig:79`), the build slot `const build_idx: u32 = 1 - self.current` (`src/v7/app.zig:1321`).

**R2 — One shared catalog per Session owner, per-App slabs and locale, shared invalidation.**
A catalog may be shared by Session owners, but each `App` retains its own two text slabs and its own locale selection. Setters invalidate the affected window through the shared W04/W05 frame-demand path and preserve the current catalog and text lifetime guarantees. *Supersedes:* a session-wide slab, a session-wide locale, and any setter that changes selection without requesting a redraw.
*Current anchors:* `Session.requestRedraw(window)` (`src/v7/session.zig:374`), already used by `App.scrollTo`/`App.scrollBy` (`src/v7/app.zig:420,426`); `FrameDemand.invalidateLayout` (`src/v7/frame_demand.zig:24`); `Session.registerApp` (`src/v7/session.zig:282`).

**R3 — `message_key` is content metadata, never identity.**
`message_key` is content metadata. It is never a `WidgetId`, never an accessibility identity, and never a list identity. Stable widget keys replace demo label-text searches. *Supersedes:* every instruction that migrates a demo label search to `.message_key`, and any step that derives identity, focus, click routing or assistive naming from a translated phrase.
*Current anchors:* `WidgetId = { owner, slot, generation }` (`src/v7/id.zig:14-17`), `FrameNodeId` (`src/v7/id.zig:4-10`), `ComponentKey` (`src/v7/key.zig:4-6`), and `DrawCtx.interactiveWidgetId`, which requires an explicit `opts.key` (`src/v7/drawctx.zig:521-529`).

**R4 — One W11 text/run/style/layout path, ranges from resolved bytes.**
Raw and localized content enter W11's same text/run/style/layout path. Compute every run range against the resolved current-locale bytes, never against a previous translation. *Supersedes:* a second measurement branch, a localized-only font or layout path, a per-locale cache, and any byte offset captured before `tr` resolves.
*Current anchors:* the shared value types `text.LayoutRequest{ content, content_generation, style, ranges, paragraph }` (`src/v7/text.zig:152-159`), `text.ByteRange`/`text.StyledRange` (`src/v7/text.zig:126-134`); the single layout measurement entry `LayoutContext.measureTextCached` and `measureDecoratedTextCached` (`src/v7/layout/context.zig:802,851`); the per-run cache clear (`src/v7/layout/dispatch.zig:44-45`); the shaping key that hashes the actual bytes and folds in `content_generation` (`src/v7_text/shape_cache.zig:346-347`, `src/v7_text/shape_cache.zig:26-38`, `src/v7_text/measure.zig:1681`).

**R5 — Declared formatter limits stand; no second cache or tree.**
Keep the formatter's declared locale, number and plural limits. Better font, shaping or bidi capability does not silently expand catalog-language support. No second shape cache and no second accessibility tree. *Supersedes:* an extra cache under the localization module, a parallel semantic tree, and any "the pipeline now supports it" argument that widens the accepted locale or plural set.
*Current anchors:* one shape cache, `src/v7_text/shape_cache.zig`, re-exported as `v7_text.shaping` (`src/v7_text/root.zig:10`); one semantics tree, `nogui.semantics` published by the W21 adapter (`src/v7_host/accessibility.zig:34,39,85`); widget semantics in the tree itself (`src/v7/headless.zig:514-515,560-567`).

## Global Constraints

- This plan does not change source, tests, README or verification assets now. The tasks below describe future implementation work, not work done.
- Keep existing string-slice widget calls working. A localized value opts in explicitly; do not localize arbitrary user data automatically.
- Do not use raw Vulkan handles. Keep relative border-box geometry and Oklab rendering unchanged.
- The lookup, argument validation, formatting and localized-widget adoption paths make no general-purpose allocator call during a frame. Catalog setup may allocate. This does not make tree growth, layout, shaping, rendering or opt-in JSON serialization allocation-free.
- Do not truncate, do not display a slug as a translation, and do not silently use a wrong plural rule when work fails.
- A presented tree and its text survive the following frame build. No translated-text reference outlives its matching frame slab.
- Localization adds no new `WidgetKind` arm, no new layout dispatch family, no new paint family, no new identity type and no new host service.

## Current source evidence (verified 2026-09-30)

Facts below were read in the current tree. They are the basis for the interface and the tasks.

- **Nothing exists yet.** A case-insensitive search of `src` for `localiz`, `catalog`, `message_key`, `LocalizedText`, `slug` and `tr(` finds no match. `src/v7/localization.zig` does not exist.
- **Text-bearing constructors copy today.** `DrawCtx.label` dupes into the frame arena (`src/v7/drawctx.zig:743-744`); `button` dupes `.label` (`:776`) and then generates a child label node that dupes the same bytes again (`:822-827` via `:744`); `slider` (`:856`), `checkbox` (`:885`), `switchControl` (`:909`), `radio` (`:933`) and `progress` (`:967`) each dupe their own text. `WidgetKind` payload fields for these seven kinds are at `src/v7/widget.zig:211-266`.
- **One measurement path already exists.** `layout/dispatch.zig:1296-1366` measures every text-bearing node through `context.measureTextCached`, `measureDecoratedTextCached` and `measureSliderContentCached`. The text-measurement cache key is the node index plus measurement input bits only (`src/v7/layout/context.zig:438-449,468-478,527-544`); it stores no text bytes, and per-pass storage is cleared at the start and end of every layout run (`src/v7/layout/dispatch.zig:44-45`). That is why a resolved phrase must be measured in the same run and why no range may survive from an earlier frame.
- **One shape cache already exists.** `src/v7_text/shape_cache.zig` is the bounded cross-frame cache, keyed by a font/style key plus a hash of the actual text bytes (`acquireWith`, `:336-371`) and re-exported once as `v7_text.shaping` (`src/v7_text/root.zig:10`). The 2026-09-25 reference to a demo-owned `src/v7_demo/text_shape_cache.zig` is stale; that file is gone.
- **One semantics tree already exists.** `src/v7/headless.zig:492-516` serializes one `NodeView` per node through `std.json.Stringify` (`:621`), including `label`, a button-only `accessible_label` (`:582-585`) and a slider-only `visual_label` (`:586-589`). `layoutFingerprint` deliberately excludes labels, values and frame counters (`src/v7/headless.zig:981-993`), so it cannot detect a same-size translation change.
- **The ASCII button path is wrong for localization.** `renderAscii` paints the semantic label directly: `drawText(grid, cols, n.kind.button.label, r, 0)` (`src/v7/headless.zig:722-729`). It must use `widget.buttonVisualLabel` (`src/v7/widget.zig:274-279`) so a hidden semantic label is not drawn. `renderAscii` itself lives in `src/v7/headless.zig:637-841`, not in the demo window.
- **Identity today.** `FrameNodeId` is frame-local (`src/v7/id.zig:4-10`); `WidgetId` is a registry handle (`src/v7/id.zig:14-17`); `ComponentKey` is a stable string or u64 (`src/v7/key.zig:4-6`); `App.widgetIdForKey(scope, key)` resolves a committed keyed handle (`src/v7/app.zig:745`); `App.activate` injects a semantic action on the committed tree only (`src/v7/app.zig:1602`).
- **The frame counter is already checked.** `present` uses `std.math.add(u64, self.frame_generation, 1) catch return error.FrameGenerationExhausted` before the arena reset (`src/v7/app.zig:1315-1316`, reset at `:1325`, commit of `self.current` at `:1565`). The 2026-09-25 instruction to convert a wrapping increment is **done**; `locale_generation` needs the same treatment for its own counter only.

- **Demo label-text searches live in the demo tests, and stable keys already exist.** `src/v7_demo/ui.zig:1319,1351,1374` match `checkbox.label == "buy milk"`, `:1322` matches `"Demo switch"`, `:1325` matches `"Choice B"`, `:1356,1379` match the footer phrases `"1 of 2 done"` and `"0 of 2 done"`, and `:1553` matches `b.label == "inc"`. Every one of those widgets is constructed with a stable key already: the todo checkbox uses `.key = .{ .u64 = item_index }` (`src/v7_demo/ui.zig:1026-1027`), the switch `.static = "demo-switch"` (`:1038-1040`), the radios `.static = "demo-radio-a"`/`"demo-radio-b"` (`:1044-1057`), the slider `.static = "volume-level"` (`:668-676`) and the counter button `.static = "counter-inc"` (`:996`). `src/v7_demo/main.zig` has no label search.
- **Build and gate commands.** `build.zig:14` defines `-Dtest-filter` as "Run tests matching a name substring". `src/v7/root.zig:163-218` is the single core test root, so a new module needs one import line there. `AGENTS.md` lists `zig build v7`, `zig build test`, `zig build lint`, `zig fmt --check src build.zig build.zig.zon` and `gate`. A name filter cannot exclude unnamed `test {}` blocks, so a filtered green run is not a whole-suite green run.
- **Demo CLI.** `src/v7_demo/main.zig:172-272` parses flags including `--frames`; a locale flag joins that loop.

**How to read the anchors.** Symbol and field names are the durable anchor. Line numbers are a snapshot read on 2026-09-30 and drift as `src/v7/app.zig` grows; re-locate a name before editing against it.

## Dated baseline observations (2026-09-25, superseded)

These were accurate when written and are kept only to explain the interface. Line ranges, file names and one instruction below no longer match the tree. Use the current section above.

- The 2026-09-25 note that `src/v7/drawctx.zig:566-826` copies labels and that a button copies twice still holds; the current range is `src/v7/drawctx.zig:743-849`.
- The 2026-09-25 note that `src/v7/app.zig:53-74,552-619,679-701` swaps the two frame arenas still holds in substance; the current anchors are `App.arenas` (`src/v7/app.zig:79`) with the build slot and reset at `src/v7/app.zig:1321-1325` and the commit at `:1565`.
- The 2026-09-25 note that `src/v7_demo/text_shape_cache.zig:1-9,572-630` owns a demo shape cache is **stale**. The cache is now `src/v7_text/shape_cache.zig`, owned by the shared text service. Never add a second one (R5).
- The 2026-09-25 note that `src/v7/headless.zig:568-614` fingerprints geometry, not text still holds; the current range is `src/v7/headless.zig:981-993`.
- The 2026-09-25 note that the default demo searches `.label == "inc"` and `"buy milk"` in `src/v7_demo/main.zig` is **stale in file only**. The searches are in `src/v7_demo/ui.zig`.
- The 2026-09-25 instruction to convert `App.frame_generation` to a checked increment is **done**; see `src/v7/app.zig:1315-1316`.
- The 2026-09-25 instruction to migrate the demo's `inc` and checkbox searches to `.message_key` is **withdrawn**. R3 forbids it: `message_key` is content metadata. Migrate to the existing stable `ComponentKey` and resolve with `App.widgetIdForKey`.

## Public interface and examples (proposed)

Put the catalog and formatter in **new** `src/v7/localization.zig`. It must not import widget, host, text or GPU types. Export the public types from `src/v7/root.zig` and add one test import there.

```zig
const std = @import("std");
const WidgetTree = @import("widget.zig").WidgetTree;

pub const max_args_per_message = 32;
pub const Locale = enum { en_us, fr_fr }; // exact tags "en-US" and "fr-FR"
pub const ArgKind = enum { text, integer, unsigned, decimal, selector };
pub const Decimal = struct { coefficient: i64, fraction_digits: u8 }; // coefficient / 10^fraction_digits; 0..6 digits
pub const Arg = union(ArgKind) {
    text: []const u8,
    integer: i64,
    unsigned: u64,
    decimal: Decimal,
    selector: []const u8,
};
pub const NamedArg = struct { name: []const u8, value: Arg };
pub const ParamSpec = struct { name: []const u8, kind: ArgKind };
pub const Variant = struct { locale: Locale, template: []const u8 };
pub const Message = struct {
    slug: []const u8,
    params: []const ParamSpec,
    variants: []const Variant,
};
pub const CatalogError = error{
    OutOfMemory, InvalidUtf8, InvalidSlug, InvalidTemplate, DuplicateMessage,
    DuplicateVariant, DuplicateArgument, TooManyArguments, UnknownArgument, MissingSourceMessage,
    SchemaMismatch, TemplateTooDeep,
};
const CompiledMessage = struct {
    slug: []const u8,
    params: []const ParamSpec,
    variants: []const CompiledVariant,
};
const CompiledVariant = struct {
    locale: Locale,
    template: []const u8,
    tokens: []const Token,
};
const Branch = struct { key: []const u8, tokens: []const Token };
const Token = union(enum) {
    literal: []const u8,
    argument: u8, // parameter index in CompiledMessage.params
    pound: u8, // nearest enclosing plural parameter index
    plural: struct { argument: u8, one: ?[]const Token, other: []const Token },
    select: struct { argument: u8, branches: []const Branch },
};
pub const ConfigureError = error{
    OutOfMemory, LocalizationAlreadyConfigured, LocalizationConfigurationTooLate,
    LocalizationNotConfigured, ZeroTextBudget, LocaleUnavailable, LocaleGenerationOverflow,
};
pub const TranslateError = error{
    LocalizationNotConfigured, MissingTranslation, InvalidArguments, InvalidUtf8,
    InvalidNumber, TextBudgetExceeded,
};
pub const LocaleParseError = error{UnsupportedLocale};
pub fn parseLocale(tag: []const u8) LocaleParseError!Locale;

pub const Catalog = struct {
    _arena: std.heap.ArenaAllocator,
    _source_locale: Locale,
    _messages: []const CompiledMessage,
    _slug_index: std.StringHashMapUnmanaged(usize),

    pub fn init(gpa: std.mem.Allocator, source: Locale, messages: []const Message) CatalogError!Catalog;
    pub fn deinit(self: *Catalog) void;
};
pub const LocalizedText = struct {
    slug: []const u8,
    text: []const u8,
    source_tree: *const WidgetTree,
    frame_generation: u64,
    locale_generation: u64,
};
```

`Catalog` stores a slug index built at initialization. Each message stores its copied slug, parameter schema and locale variants. Each variant stores compiled tokens for literals, named arguments, plural branches and select branches. Use arena-owned immutable slices for the compiled representation.

Use `_arena` for all catalog-owned bytes and for the unmanaged slug index. Store copied templates alongside compiled tokens; literal tokens may borrow their copied template. Build the index with `_arena.allocator()` and release all state with one arena deinit. One caller may hand the same `*const Catalog` to several `App` owners in one `Session` (R2); the catalog stays immutable and each `App` keeps its own slabs and locale.

```zig
// Add inside App in src/v7/app.zig:
pub fn configureLocalization(self: *App, catalog: *const Catalog, locale: Locale, bytes_per_frame: usize) ConfigureError!void;
pub fn setCatalog(self: *App, catalog: *const Catalog) ConfigureError!void;
pub fn setLocale(self: *App, locale: Locale) ConfigureError!void;
// Add inside DrawCtx in src/v7/drawctx.zig:
pub fn tr(self: *DrawCtx, slug: []const u8, args: []const NamedArg) TranslateError!LocalizedText;
```

These are target signatures. `LocalizedText` carries the originating tree and both generations so constructors can reject stale data. `App` methods use `ConfigureError`; `DrawCtx.tr` uses `TranslateError`.

The caller owns each `Catalog` and keeps it alive while at least one `App` has it installed. Deinitialize every `App` before deinitializing a shared catalog. Each `App` owns its own two text slabs and frees them in `App.deinit`. Configure localization once per `App`, before that App's first frame attempt, with a nonzero fixed `bytes_per_frame` such as 64 KiB. Configuration requires a catalog variant for the selected locale. A duplicate configuration returns `error.LocalizationAlreadyConfigured`. A configuration after that App's first frame attempt returns `error.LocalizationConfigurationTooLate`.

Allocate both slabs before storing the catalog, locale or configured state. If either allocation fails, free any slab allocated by that attempt and leave the `App` unconfigured.

Call `setCatalog` and `setLocale` only after configuration and between frames. Both return `error.LocalizationNotConfigured` before setup. A failed setter leaves the selection and generation unchanged. `setCatalog` returns `error.LocaleUnavailable` if the selected locale has no variants in that catalog. A successful replacement makes it safe for the caller to destroy the old catalog, because retained frame text lives in `App`-owned slabs. Setting the same catalog pointer or locale is a no-op. Never mutate an installed catalog.

**Each successful setter also requests a redraw for that `App`'s window through the shared frame-demand path** (R2): call `self.session.requestRedraw(self.window)`. A locale or catalog change changes text, measurement and semantics, so a settled window must wake up on its own. A no-op setter requests nothing. A setter that fails requests nothing.

At `App.present`, select the text slab paired with `build_idx` after resetting `arenas[build_idx]` (`src/v7/app.zig:1321-1325`). Reset that slab's cursor and pass `DrawCtx` a borrowed catalog, active locale, frame and locale generations, tree pointer, slab bytes and cursor pointer. `DrawCtx.tr` returns `error.LocalizationNotConfigured` when no catalog is installed. Catalog lookup uses its prebuilt slug index. The formatter reads compiled tokens and writes the slug metadata and final text straight into that slab. It calls no allocator and produces no intermediate string.

Use `max_args_per_message` as the explicit schema limit. Validate named arguments into `[max_args_per_message]Arg` and a parallel seen array on the stack. Caller order stays independent, compiled parameter indices give constant-time access during formatting, and no per-call heap storage is needed.

```zig
var catalog = try nogui.Catalog.init(gpa, .en_us, &.{
    .{
        .slug = "todo.completed",
        .params = &.{
            .{ .name = "count", .kind = .unsigned },
            .{ .name = "total", .kind = .unsigned },
        },
        .variants = &.{
            .{ .locale = .en_us, .template = "{count, plural, one {# task completed} other {# tasks completed}} of {total}" },
            .{ .locale = .fr_fr, .template = "{count, plural, one {# tâche terminée} other {# tâches terminées}} sur {total}" },
        },
    },
    .{
        .slug = "todo.increment",
        .params = &.{},
        .variants = &.{
            .{ .locale = .en_us, .template = "Increment" },
            .{ .locale = .fr_fr, .template = "Augmenter" },
        },
    },
    .{
        .slug = "player.volume",
        .params = &.{},
        .variants = &.{
            .{ .locale = .en_us, .template = "Volume" },
            .{ .locale = .fr_fr, .template = "Volume" },
        },
    },
});
defer catalog.deinit();
var session = try nogui.Session.init(gpa);
defer session.deinit() catch unreachable;
var app = try nogui.App.init(gpa, &session);
defer app.deinit();
try app.configureLocalization(&catalog, .fr_fr, 64 * 1024);

// Inside a component's draw(self, ctx):
const completed = try ctx.tr("todo.completed", &.{
    .{ .name = "count", .value = .{ .unsigned = self.done_count } },
    .{ .name = "total", .value = .{ .unsigned = self.visible_count } },
});
_ = try ctx.label(.{ .text = completed });
_ = try ctx.button(.{
    .key = .{ .static = "counter-inc" }, // stable widget key, not the slug
    .label = try ctx.tr("todo.increment", &.{}),
    .on_click = Self.inc,
});
_ = try ctx.slider(.{
    .key = .{ .static = "volume-level" },
    .label = try ctx.tr("player.volume", &.{}),
    .visual_label = "", // hidden visual text, still a translated semantic name
    .value = &self.volume,
    .min = 0,
    .max = 1,
});
```

`LocalizedText` carries `slug`, `text`, the originating tree, the frame generation and the locale generation. Its slices borrow the current slab. Primary text fields accept it: `.text` for `label`, and `.label` for `button`, `slider`, `checkbox`, `switchControl`, `radio` and `progress`. Keep `visual_label` and `accessible_label` overrides as caller-owned strings copied into the frame. Constructors reject values from another tree or generation with `error.StaleLocalizedText`. Localization does not change button callbacks or bound-control activation.

## Catalog, formatting and error policy

1. **Key space.** A slug is a nonempty ASCII identifier of letters, digits, dots, underscores and hyphens. Each `Message` defines one argument schema and one source-locale variant. Reject duplicate slugs, duplicate locales per message, duplicate parameter names, unknown parameter references in any variant, inconsistent parameter uses, invalid UTF-8 and malformed templates at `Catalog.init`. A translation may omit an argument but may not redefine its type. Callers pass every declared argument exactly once, with its declared union tag. Build the slug index and the parsed branch tokens at init, never during draw. A slug is content metadata: it never keys a component, a widget, a focus target or a list row (R3).
2. **Fallback.** On each `tr`, look for `(active locale, slug)`, then `(catalog source locale, slug)`. A missing active-locale variant for a known slug uses its source translation. A locale is available when at least one catalog message has a variant for it; other messages fall back individually. Unknown slugs return `error.MissingTranslation`; never draw the slug, an empty substitute or unrelated text. `setLocale` and `setCatalog` return `error.LocaleUnavailable` when the target locale has no variants. `parseLocale` accepts only the exact tags `en-US` and `fr-FR` and returns `error.UnsupportedLocale` for anything else. Adding another locale requires a tested formatter and plural rule first (R5).
3. **Grammar.** A template contains literal UTF-8, `{name}` insertion, `{n, plural, one {...} other {...}}`, and `{choice, select, admin {...} other {...}}`. Parameter names use ASCII `[A-Za-z_][A-Za-z0-9_]*`. Select keys use ASCII letters, digits, `_` and `-`. A select compares the selector argument exactly with a key. A plural supports only `one` and `other`; `other` is mandatory, and a missing category uses `other`. Branches may nest to a maximum depth of eight; reject deeper catalogs. A plural argument must be `.integer` or `.unsigned`. `#` in a plural branch emits that branch's plural argument with locale number formatting; in nested plural branches it uses the nearest enclosing plural. A select argument must be `.selector`; unknown values take `other`. Support `\{`, `\}`, `\#` and `\\` for literal syntax characters. Reject unknown escapes, repeated branch keys, unmatched braces, a bare `#` outside a plural branch, and unsupported ICU directives. This is a documented subset, not a claim of ICU MessageFormat compatibility.
4. **Plural rules and numbers.** For cardinal integer values, English `one` means exactly 1; French `one` means 0 or 1. All other values, including negatives, use `other`. Never infer the plural category from a formatted string. Decimal arguments do not drive plural branches. Format `.text` and `.selector` as literal UTF-8. Format `.integer` and `.unsigned` with locale grouping. Group thousands with `,` in English and U+202F NARROW NO-BREAK SPACE in French. Format `.decimal` with its specified fraction digits, grouping and decimal separator. For coefficient 1234550 with two fraction digits, render English `12,345.50` and French `12 345,50`. Preserve trailing zeroes and use exact integer arithmetic for signs, grouping and `minInt(i64)`. Reject precision above six with `InvalidNumber`. These limits do not widen because shaping or bidi improves (R5).
5. **Escaping and encoding.** Validate catalog bytes once and `.text`/`.selector` arguments at each call. Reject embedded NUL, DEL and C0 controls except tab, LF and CR. Literal template text may use those same three controls. Insert argument text as literal UTF-8, without re-parsing braces or treating `<` as markup. JSON emission must use `std.json.Stringify` (`src/v7/headless.zig:621`) so quotes and control characters are escaped there, not in shaped text. Do not split UTF-8 sequences when the slab fills; fail before exposing a truncated result.
6. **Failures.** Catalog construction reports `OutOfMemory`, `InvalidUtf8`, `InvalidSlug`, `InvalidTemplate`, `DuplicateMessage`, `DuplicateVariant`, `DuplicateArgument`, `TooManyArguments`, `UnknownArgument`, `MissingSourceMessage`, `SchemaMismatch` or `TemplateTooDeep` as applicable. Draw-time translation reports `LocalizationNotConfigured`, `MissingTranslation`, `InvalidArguments`, `InvalidUtf8`, `InvalidNumber` or `TextBudgetExceeded`. Widget constructors report `StaleLocalizedText` before node creation. App configuration reports `OutOfMemory`, `LocalizationAlreadyConfigured`, `LocalizationConfigurationTooLate`, `LocalizationNotConfigured`, `ZeroTextBudget`, `LocaleUnavailable` or `LocaleGenerationOverflow`. On any `tr` failure, rewind the slab cursor to its position at call entry and expose no partial result. Propagate draw errors through `App.present`.

## Identity, accessibility and frame lifetime

- Add `message_key: ?[]const u8` to the label, button, slider, checkbox, `switch_control`, radio and progress payloads in `src/v7/widget.zig` (`:211-266`). For localized text it holds the slug copied into the current slab; for literal text it stays null. The field is content metadata for diagnostics, automation and JSON. It is **not** a `ComponentKey`, **not** a `WidgetId`, **not** an accessibility name and **not** a list identity (R3). Widget identity, click routing, focus and pressed-state reconciliation stay exactly as they are today (`src/v7/drawctx.zig:521-529`, `src/v7/app.zig:1602`).
- A localized button's semantic `.label` is translated; its generated child reuses the same resolved slice when `.visual_label` is null. An icon or an empty `.visual_label` hides visible text but keeps the translated accessible name. A slider's semantic label stays available when its visual label is empty. Checkbox, switch, radio and progress labels are translated direct-text leaves; checked, selected and value state never becomes part of the translation key. Default accessible names to the semantic label, and let literal `accessible_label` overrides win. Report them through the existing semantic node and the existing W21 publisher; add no second tree (R5). This plan does not claim an operating-system accessibility bridge beyond what W21 already ships.
- Include `message_key` and the resolved accessible name for every text-bearing kind in headless JSON, while keeping `label` human-readable and the existing checked, selected, value, min and max fields intact. Extend the one `NodeView` struct (`src/v7/headless.zig:492-516`); do not add a second serializer.
- Automation keys on the stable widget key, not on phrases and not on `message_key`. Migrate the demo searches at `src/v7_demo/ui.zig:1319,1351,1374,1322,1325,1356,1379,1553` to resolve `ComponentKey` through `App.widgetIdForKey` (`src/v7/app.zig:745`) using the keys the demo already supplies (`src/v7_demo/ui.zig:996,1027,1040,1045,1053,669`). Footer phrases stay asserted as phrases, because that assertion is about the rendered phrase, not about identity.
- Fix the ASCII button path to draw visible text: `renderAscii` must use `widget.buttonVisualLabel` (`src/v7/widget.zig:274-279`) instead of the semantic label at `src/v7/headless.zig:728`.
- `App` allocates two fixed text slabs in `configureLocalization` and frees them in `deinit`. At the start of `present`, clear only the slab paired with `build_idx`, at the same point the matching arena is reset (`src/v7/app.zig:1321-1325`). The other slab keeps the last presented tree's strings alive. Stream final UTF-8 bytes straight into the current slab with a checked bump cursor. Copy the slug into that slab once as metadata. Use bounded stack scratch for number formatting. On a budget error, rewind to the cursor at call entry. Every successful result is immutable until its slab resets. No widget may retain a slice into a caller's scratch buffer or into catalog memory.
- Refactor the seven text-bearing constructors (`src/v7/drawctx.zig:743-987`) around one internal text-adoption helper. A legacy `[]const u8` primary text still needs exactly one frame-owned copy. A `LocalizedText` needs none after `tr` (R1). A button's generated child reuses the parent's resolved slice. Copy optional literal visual and accessible overrides at most once each. Resolve text options before appending the first widget node.
- `App` owns a checked monotonic `locale_generation`. Configuration starts at generation 1. A real catalog replacement or locale change increments it; setting the same pointer or locale again is a no-op. Use `std.math.add` with a catch, exactly as `frame_generation` already does at `src/v7/app.zig:1315-1316`, and return `error.LocaleGenerationOverflow` without changing state instead of wrapping. Do not touch `frame_generation`; it is already checked. Store the last successfully built locale generation in nullable `App.tree_locale_generation`. Add nullable `FrameOutput.locale_generation` for `tree` and `FrameOutput.prev_locale_generation` for `prev_tree`. `locale_generation` is null when localization is not configured. `prev_locale_generation` is null when localization is not configured or there is no previous tree. Capture the previous generation before updating the current one. A consumer comparing `prev_tree` with `tree` compares the locale generation, not text length and not the layout fingerprint, which excludes text by design (`src/v7/headless.zig:981-993`).
- Use the existing `App.frame_generation` as the frame token in `LocalizedText` and `DrawCtx`. The tree pointer plus the frame token rejects stale values even when a frame arena reuses the same tree address two frames later. No extra frame counter is needed.

## One text path, and ranges from resolved bytes

R4 is the rule that most easily breaks, so it is stated operationally here.

- **The resolved slice is the only content.** `DrawCtx.tr` writes the final bytes into the current slab. Whatever the constructors adopt is a slice of those exact bytes, and nothing re-encodes, re-normalizes or re-copies them. A raw `[]const u8` label and a translated label must reach layout as the same kind of value: plain `[]const u8` content. There is no "localized" variant of the node, the layout request, the style or the paint record.
- **Measurement is already shared.** `layout/dispatch.zig:1296-1366` measures the node's text for all seven kinds through `LayoutContext.measureTextCached` and `measureDecoratedTextCached`. A translated label changes only which bytes those functions receive.
- **The measurement cache carries no bytes, so nothing may survive from a previous frame.** `TextMeasurementCache.key` is the node index plus measurement input bits (`src/v7/layout/context.zig:446-449,468-478`). Per-pass storage is cleared at the start and end of every layout run (`src/v7/layout/dispatch.zig:44-45`), so a locale change is measured fresh in the next frame. A consumer that stores a measured size, a wrap point or a caret offset across a locale change is storing a previous translation's geometry and must discard it.
- **Run ranges are computed after resolution.** Any `text.ByteRange` or `text.StyledRange` (`src/v7/text.zig:126-134`) applied to a translated run must be derived from the slice `tr` just returned, in this frame. Compute it after `tr`, not from the template, not from the source-locale phrase, and not from the previous frame's phrase. A template cannot produce valid ranges: the formatted argument text changes the byte offsets.
- **Shaping already keys on the resolved bytes.** The shared cache hashes the emitted text and folds in `content_generation` (`src/v7_text/shape_cache.zig:346-347`, `:26-38`, `src/v7_text/measure.zig:1681`), so a changed translation reshapes and an unchanged one reuses the retained run. Do not add a per-locale cache to make this cheaper (R5).
- **Direction and script stay the W11 defaults.** `text.Paragraph.direction` and the shaping `script` continue to be resolved by W11 from the actual bytes. That is a layout capability, not a statement about catalog-language support; `parseLocale` still rejects any tag other than `en-US` and `fr-FR` (R5).

## Alternatives and design risks

| Alternative | Benefit | Why not selected here |
| --- | --- | --- |
| Per-widget `Tr` constructor methods | One call per widget | Repeats the existing text and style surface for seven kinds and makes visual overrides harder to express. One `ctx.tr` value composes with all text-bearing constructors. |
| Persist formatted text in a catalog cache | Avoids repeat formatting for unchanged arguments | Cache keys and eviction would retain dynamic user text, need allocator work on misses, risk old-frame or stale-locale references, and would be a second cache next to the W11 shape cache (R5). |
| Format with `allocPrint`, then pass text to existing widgets | Easy first patch | Copies every result at least twice into frame storage, and a button copies again for its child. It also forces a per-frame allocator on the draw path. |
| Session-wide text slab and locale | One configuration for a whole app | Breaks per-window independence: one window's catalog change would restate another window's text and its two-frame lifetime. Each `App` keeps its own slabs and locale (R2). |
| A dedicated localized text node or kind | Could carry the slug in the node tag | Adds a layout dispatch family, a paint family and a second measurement route for text that is ordinary text. The slug belongs in existing payload metadata (R3, R4). |
| A localization-owned accessibility tree | Could name nodes by slug | Duplicates W21's `nogui.semantics` publication. Message keys are not accessibility identity (R3, R5). |
| General ICU/CLDR language engine | Covers more scripts and rules | Requires language data, bidi-aware shaping, font coverage and broader tests. The limited locale set reports unsupported locales rather than guessing (R5). |

- **Catalog ownership.** `App` borrows its installed immutable catalog. A replacement releases the old borrow after the setter succeeds; current and previous frame text stay valid because each tree points into an `App`-owned slab. A catalog may be shared by several `App` owners in one `Session`; the last of them must release its borrow before the catalog is deinitialized (R2).
- **Capacity.** A fixed 64 KiB example budget overflows with many labels or long untrusted arguments. The caller sizes `bytes_per_frame` for the scene. Tests must prove `TextBudgetExceeded` leaves earlier output intact. Slabs never grow inside a frame.
- **Renderer limits.** The shape cache resolves font, script and direction per run from the actual bytes (`src/v7_text/shape_cache.zig:26-38`). French accent glyph coverage and punctuation still need checking on a real window with the shipped fonts. This plan does not promise Arabic, RTL, bidirectional isolation or generalized Unicode collation, and improved shaping capability does not widen the catalog locale set (R5).
- **Measurement staleness.** The per-node measurement cache stores no text bytes (`src/v7/layout/context.zig:438-449`). A locale change is safe only because every layout run starts with cleared per-pass storage (`src/v7/layout/dispatch.zig:44-45`). Any change that makes text measurement survive a run also makes stale translated measurements reachable; treat that as a blocker, not a tuning knob.
- **Identity drift.** A translated phrase must never reach `ComponentKey`, `WidgetId`, focus or a list row (R3). The demo's existing stable keys (`src/v7_demo/ui.zig:996,1027,1040,1045,1053,669`) are the supported way to address a localized widget.
- **Generation and lifetime.** Two live trees may show different locales. A premature slab reset, a retained `LocalizedText` in component state, or a same-size translated label treated as clean would show stale text. Test the current and previous frame together.
- **Schema evolution.** Reordering placeholders is safe. Adding or removing a parameter changes a slug's public schema. Reject mismatched catalog variants instead of rendering partial text. Do not reuse a slug for a different meaning.
- **Demo coupling.** The demo label searches in `src/v7_demo/ui.zig` are test-only. Migrate them to stable keys in the same commit that adds the localized demo route, so no window exists in which a locale change silently stops injected clicks.

## Ordered implementation checklist

Each task writes a failing behavioral test first, runs the named filter to observe a red result, implements only the named behavior, then runs the same filter for green. The commands are for the **future implementation**; none were executed while reconciling this plan. `build.zig:14` supplies `-Dtest-filter` across the Zig test roots and `src/v7/root.zig:163-218` is the single core test root. A name filter cannot exclude unnamed `test {}` blocks, so a filtered green run is not a whole-suite green run. Do not edit golden files or weaken tests to obtain green.

### Task 1 — Compile an immutable catalog and decide fallbacks

**Files:** create `src/v7/localization.zig`; modify `src/v7/root.zig` to export its public types and import it in the test root. No GPU, host or text dependency, no second root, no second cache (R5).

- [ ] Write `localization catalog` tests in `src/v7/localization.zig`. Assert source and active lookup, a missing active entry falling back to source, an unknown slug failing, exact `en-US` and `fr-FR` parsing with unsupported-tag rejection, duplicate slug, locale and argument rejection, 32 arguments accepted and 33 rejected, unknown argument references, malformed escapes and braces, bad UTF-8, a missing source variant, and nine-level nesting rejection. Verify a failed `init` releases all memory with `std.testing.allocator`. Assert that one catalog can back two `App` owners at once without either mutating it (R2).
- [ ] Run `zig build test -Dtest-filter="localization catalog"`. **Red:** the catalog interface or the assertions fail. Implement owning copies, the compiled template parser, validated schemas and allocation-free lookup. **Green:** repeat the same command; every new case passes without leaks. Leave the accepted locale set at exactly two tags.

### Task 2 — Format typed arguments into bounded frame storage

**Files:** modify `src/v7/localization.zig`; add its formatter tests there. Keep the formatter independent of widget, text and GPU types.

- [ ] Write `localization format` tests for reordered and repeated `{name}`, literal escaped braces and `#`, nested plural `#` binding, duplicate branch rejection, unparsed hostile text, `select` `admin` and `other`, English counts 0, 1, 2, French counts 0, 1, 2, a signed minimum, grouped integers, both decimal separators, exact fixed-point decimals with preserved trailing zeroes, precision above six, wrong, missing, extra and duplicate arguments, invalid UTF-8, and exact-budget and one-byte-short cases. After a budget error, assert the next valid call starts at the old cursor.
- [ ] Run `zig build test -Dtest-filter="localization format"`. **Red:** the tests fail before formatting exists. Compile branch tokens at catalog init. Stream bytes into caller-provided fixed storage with checked cursor arithmetic and stack-only argument and number scratch. **Green:** rerun the command; texts and errors match the cases above. Add a counting, failing allocator around the prepared lookup and format path and assert zero allocator calls during these requests.

### Task 3 — Pair translated text with each App's own frame arenas

**Files:** modify `src/v7/app.zig`, `src/v7/drawctx.zig`, `src/v7/headless.zig`; add the `App` tests in `app.zig`.

- [ ] Write `App localization` tests for: configuring before the first frame attempt; rejecting duplicate and late configuration; unconfigured `tr`; pre-configuration setters; unavailable locales with no state change; same-locale and same-catalog no-ops; a locale or catalog change between frames; a `Session` with two `App` owners sharing one catalog while each keeps its own slabs, locale and text (R2); a redraw request from each successful setter and none from a no-op or failed setter (R2); previous-tree text survival during the next build; and `StaleLocalizedText` after the same arena and tree address are reused two frames later. Test an oversized translation followed by a good frame on the same `App`. Assert a same-size changed phrase increments `locale_generation`, that `FrameOutput.prev_locale_generation` stays tied to the previous tree, and that locale-generation overflow preserves prior state without resetting the arena.
- [ ] Run `zig build test -Dtest-filter="App localization"`. **Red:** the `App` and `DrawCtx` contract is absent. Allocate both slabs once per `App`, pair the reset with `build_idx`, propagate the generations through `DrawCtx` and `FrameOutput`, keep the setters atomic, call `self.session.requestRedraw(self.window)` on a real change, and return the typed errors. **Green:** rerun the command. Check that `prev_tree` still holds the old text while `tree` holds the new text, even when their node IDs match.

### Task 4 — Adopt one resolved slice in all seven text widgets

**Files:** modify `src/v7/drawctx.zig`, `src/v7/widget.zig`, `src/v7/headless.zig`. Review `src/v7/layout/dispatch.zig` and `src/v7/layout/context.zig`; change them only if a text path fails to consume the resolved bytes. Do not add a `WidgetKind` arm, a measurement branch or a paint family (R4).

- [ ] Write `DrawCtx localization` tests for translated labels, buttons, sliders, checkboxes, switches, radios and progress captions; raw-slice compatibility; null versus empty visual overrides; icon accessibility; literal accessible-name overrides; cross-frame `StaleLocalizedText`; a failed resolution leaving the tree unchanged; and `message_key` present for localized text and null for literal text. Assert the button parent and its generated child share one text slice. Assert that the seven kinds reach the existing measurement entry with the resolved bytes and that a locale change re-measures rather than reusing the previous frame's size. Assert that no run range is accepted from a previous frame's bytes.
- [ ] Run `zig build test -Dtest-filter="DrawCtx localization"`. **Red:** the constructors still duplicate, or cannot accept `LocalizedText`. Centralize text adoption, copy legacy raw slices once, borrow validated localized slices, add the optional `message_key` metadata field, and fix the ASCII button path to paint `widget.buttonVisualLabel`. **Green:** rerun the filter; the button child and parent point to the same frame-owned bytes. Keep callbacks, bound-control behavior, typed style resolution and relative geometry unchanged.

### Task 5 — Expose stable semantics and exercise the running demo

**Files:** modify `src/v7/headless.zig`, `src/v7_demo/ui.zig`, `src/v7_demo/main.zig`. Review `src/v7_host/accessibility.zig` and `src/v7_text/shape_cache.zig`; change them only if a text or semantic path fails to consume the resolved bytes. No build-system change is needed: `src/v7/root.zig:163-218` is the single core test root and gains one import line in Task 1.

- [ ] Write `localization semantic` tests that compare JSON `message_key`, the translated `label`, the resolved accessible name and the preserved checked, selected and progress state for every text-bearing kind. Verify JSON escaping for quotes and backslashes and for literal braces in arguments. Verify that the ASCII map draws the visible text of an icon button and not its hidden semantic label. Verify that a `message_key` never resolves as a widget or focus identity, and that the existing semantic tree still carries the localized name through the current W21 path.
- [ ] Run `zig build test -Dtest-filter="localization semantic"`. **Red:** the JSON, ASCII and identity expectations fail. Add one `message_key` field and a resolved accessible name to the existing `NodeView`, fix the ASCII button arm, and keep the `std.json.Stringify` path (`src/v7/headless.zig:621`). **Green:** rerun the filter; default-scene behavior stays unchanged.
- [ ] Migrate the demo's label-text searches in `src/v7_demo/ui.zig` to the stable widget keys the demo already supplies, resolved through `App.widgetIdForKey`: the checkbox at `:1319,1351,1374` uses `.key = .{ .u64 = item_index }`, the switch at `:1322` uses `"demo-switch"`, the radio at `:1325` uses `"demo-radio-b"`, and the button at `:1553` uses `"counter-inc"`. Do not route any of these searches through `message_key` (R3). Keep the footer phrase assertions at `:1356,1379` unchanged: they drive the default route, which stays literal English, and they assert a rendered phrase rather than an identity. A translated footer is a separate assertion on the opt-in route below, not a rewrite of these two.
- [ ] Add an opt-in `--l10n-demo --locale en-US|fr-FR` route to `TodoApp` in `src/v7_demo/main.zig`, parsing exact tags in the existing flag loop and propagating `error.UnsupportedLocale`. Install the two-locale catalog before the first frame, and localize the completed-count footer, the `inc` button, the volume slider, one todo checkbox, the switch, the radio choices and the progress caption **on that route only**; the default route keeps its literal strings, so no existing demo assertion changes. Call `setLocale` for locale switches so the window wakes through the shared frame-demand path (R2).
- [ ] Run `zig build v7 -- --l10n-demo --locale fr-FR --frames 3` on a host with a window and GPU, then inspect accented glyphs and clipping on screen.
- [ ] Run `zig build test`, then the repository gate, after all implementation edits land. **Expected:** existing tests pass, new behavioral tests pass, and no default-scene golden file needs modification, since `layoutFingerprint` excludes labels by design (`src/v7/headless.zig:981-993`). If a check fails, fix the product behavior or a genuinely obsolete assertion; do not change verification assets to hide the failure.

## Acceptance and handoff risks

Implementation is complete only when callers translate with typed arguments during `draw`; all seven text-bearing widgets display or expose the correct text; raw and localized text use the same measurement, style, layout and semantic path; fallback and errors follow the rules above; a locale or catalog change wakes the window through the shared frame-demand path; run ranges derive from the resolved bytes of the current frame; and two live frame outputs remain valid. Filtered red/green tests and the running demo must show those results. The fixed text budget and the two-tag locale set are explicit interface limits, not silent fallbacks.

Completing this plan does not complete GPUI API parity, and the parity plan does not gain a localization capability from it. If a later worker finds that implementing R4 needs a second measurement route, a per-locale cache or a second semantics tree, that is a defect in the approach, not a reason to widen the rules.

## Evidence summary

**Current source evidence, verified 2026-09-30 in this tree:** no localization code exists; the seven constructors copy their text in `src/v7/drawctx.zig:743-987`; one shared measurement path exists in `src/v7/layout/dispatch.zig:1296-1366` with a byte-free, node-indexed cache key at `src/v7/layout/context.zig:438-449` cleared per run at `src/v7/layout/dispatch.zig:44-45`; one shape cache exists at `src/v7_text/shape_cache.zig` and hashes the emitted bytes; one JSON view and one semantics tree exist at `src/v7/headless.zig:492-516` and `src/v7_host/accessibility.zig:34`; the ASCII button arm paints the semantic label at `src/v7/headless.zig:728`; shared invalidation is `Session.requestRedraw` at `src/v7/session.zig:374`; `frame_generation` is already checked at `src/v7/app.zig:1301-1302`; and every demo widget the label searches target already carries a stable key at `src/v7_demo/ui.zig:669,996,1027,1040,1045,1053`.

**Future product work, not started and not verified here:** every declaration in this plan, the five tasks, the demo route, and every red/green run listed above. No build, test, lint or format command was executed while reconciling this document; this change is docs-only.
