//! Frame-local overlay placement over stable widget handles.
//!
//! The caller builds content normally and registers one record per popup,
//! then placement runs in three steps: `stage` resolves geometry, clip and
//! the record each placed subtree belongs to; `finalizePaintOrder` assigns
//! every placed subtree a disjoint paint band above the application; and
//! `commit` publishes both with the tree they were resolved against.
//!
//! Placement is ONE geometry: it moves the content root's RELATIVE border
//! box, and every descendant inherits that move through
//! `widget.visualBorderRect`. Paint, input, semantics and inspection all read
//! the tree's own boxes, so they cannot drift apart, and no second copy of
//! the geometry is stored. The paint band travels the same way, as
//! `WidgetNode.placement_paint`: a band is part of the tree it resolved
//! against, not of the bank that resolved it.
//!
//! Paint order and hit order are ONE ordering. The painter ranks a node by
//! `widget.effectiveLayer`, which is its authored layer raised by the band in
//! its own `placement_paint`; `Frame.hitTest` ranks by that same
//! `placement_paint.order`, per node. Neither consults a second,
//! placement-level list, so a topmost-painted overlay cannot lose input to
//! the underlay it is drawn over.
//!
//! A record that resolves to NOTHING is a DORMANT overlay: its content stays
//! laid out, filled and authored visible, and the frame marks that subtree
//! with `WidgetNode.overlay_dormant` so the ordinary paint and hit walks skip
//! it. The marker travels like the moved origin and the band — by value, in
//! the tree — and every walk reads it, so nothing painted, nothing routed and
//! nothing ringed can disagree about a dismissed popup. An unplaced record
//! gets no band and does not lift the application maximum; its own raw layer
//! is untouched, so the very same record counts again the moment an anchor
//! places it.
const std = @import("std");
const widget = @import("widget.zig");
const input = @import("input.zig");
const focus = @import("focus.zig");
const WidgetId = @import("id.zig").WidgetId;
const FrameNodeId = @import("id.zig").FrameNodeId;

pub const ClipPolicy = enum {
    /// The anchor's clipping ancestors clip this popup too. The clip is
    /// IMPOSED on the content root as `WidgetNode.placement_clip`, which the
    /// popup's own box does not shrink: paint, hit and inspection all reduce
    /// that one field through `widget.pointInClipChain`. The placement owns
    /// the field, so staging a record replaces whatever the last resolution
    /// imposed and `window_escape` never inherits a stale clip.
    inherit,
    /// The anchor's clipping ancestors do not clip this popup. The popup's own
    /// ancestry in the tree still applies — that is the tree's one rule, not a
    /// second derivation.
    window_escape,
};
pub const Side = enum { below, above, right, left };
pub const Record = struct {
    anchor: WidgetId,
    /// Root of a content subtree built in this frame. It must have a stable key.
    content: WidgetId,
    side: Side = .below,
    gap: f32 = 0,
    margin: f32 = 0,
    clip: ClipPolicy = .inherit,
    priority: u31 = 0,
    modal: bool = false,
};
pub const Placement = struct {
    record: Record,
    /// Where the content root now sits, after the move. Its descendants sit
    /// where the tree's own parent walk puts them.
    rect: widget.Rect,
    /// Registration index of `record`. It is the identity a placed node's
    /// band is looked up by, so a node never searches the placements.
    record_index: u32,
    /// (priority, registration): the paint-band and hit-routing key, both
    /// derived from the same comparator.
    order: u64,
};
pub const Error = error{ InvalidGeometry, DuplicateContent, OverlayFrameNotAttached, PaintLayerOverflow } ||
    std.mem.Allocator.Error;

/// One registered record's resolution, indexed by REGISTRATION index: `span`
/// is the highest raw local layer a placed subtree emits, `layer` the base
/// they are added to, `placed` whether the record resolved to anything at all,
/// and `root` the content node whose subtree this record names. One entry per
/// registered record, so tagging a node in stage and reading its band in
/// finalize are both O(1) and no node needs a pointer into the bank. The array
/// is sized in stage, so neither pass allocates.
const Band = struct {
    span: u32,
    layer: u32,
    placed: bool,
    /// The content node whose subtree this record names, or `.root` for a
    /// record whose content this frame did not publish. The per-node pass
    /// compares this id against the node's own ancestor chain, so it never
    /// searches the placements for a node.
    root: FrameNodeId,
};

/// One frame's registrations and its resolution. A frame keeps TWO of these
/// and swaps them: the staged bank belongs to the frame being built, the
/// committed bank to the tree the App published. Each bank owns its own
/// storage, so staging and committing allocate only when a frame exceeds the
/// high-water mark seen so far — never per frame.
const Bank = struct {
    records: std.ArrayList(Record) = .empty,
    placements: std.ArrayList(Placement) = .empty,
    bands: std.ArrayListUnmanaged(Band) = .empty,
    /// The tree these placements were resolved against. Null means this bank
    /// answers for nothing, so a bank can never route a point against a tree
    /// it never resolved.
    tree: ?*const widget.WidgetTree = null,

    fn deinit(self: *Bank, gpa: std.mem.Allocator) void {
        self.bands.deinit(gpa);
        self.placements.deinit(gpa);
        self.records.deinit(gpa);
        self.* = undefined;
    }
};

pub const Frame = struct {
    gpa: std.mem.Allocator,
    staged: Bank = .{},
    committed: Bank = .{},

    pub fn init(gpa: std.mem.Allocator) Frame {
        return .{ .gpa = gpa };
    }

    /// Forget every resolution. The registered records are the caller's list
    /// and describe what the next frame should place, so they stay.
    ///
    /// An owner calls this before the tree a bank names is freed, so a mounted
    /// frame can never outlive the tree it placed into.
    pub fn invalidate(self: *Frame) void {
        self.staged.tree = null;
        self.committed.tree = null;
    }

    pub fn deinit(self: *Frame) void {
        self.staged.deinit(self.gpa);
        self.committed.deinit(self.gpa);
        self.* = undefined;
    }

    /// The bank that resolved `tree`, or null when neither did. Selection is
    /// by tree, so a query against the frame being built reads the staged bank
    /// and a query against the published tree reads the committed one — never
    /// this frame's records against somebody else's placements.
    ///
    /// STAGED first, because a staged bank only names a tree it resolved in
    /// the resolution that is still being built: `commit` clears the recycled
    /// bank's tree, and a failed `stage` leaves nothing behind. So when both
    /// name one tree — a caller that resolves the same tree again — the staged
    /// answer is the newer one, and reading the committed bank instead would
    /// report the previous frame's popups for this frame's tree.
    fn bankForTree(self: *const Frame, tree: *const widget.WidgetTree) ?*const Bank {
        if (self.staged.tree == tree) return &self.staged;
        if (self.committed.tree == tree) return &self.committed;
        return null;
    }

    /// The registrations in force for `tree`, or null when it was never
    /// placed. Building a frame against ANOTHER tree never changes the
    /// records that describe the tree the App is already routing.
    pub fn records(self: *const Frame, tree: *const widget.WidgetTree) ?[]const Record {
        const owned = self.bankForTree(tree) orelse return null;
        return owned.records.items;
    }

    pub fn add(self: *Frame, record: Record) Error!void {
        if (!std.math.isFinite(record.margin) or record.margin < 0 or
            !std.math.isFinite(record.gap) or record.gap < 0) return error.InvalidGeometry;
        for (self.staged.records.items) |existing| {
            if (existing.content.eql(record.content)) return error.DuplicateContent;
        }
        try self.staged.records.append(self.gpa, record);
    }

    /// Start one frame's registrations. Records describe this frame's popups,
    /// so a caller that re-registers them during its draw begins here; the
    /// previous frame's records belong to the committed bank and stay there.
    ///
    /// The staged resolution is dropped with them. A frame that failed AFTER
    /// staging left the staged bank naming a tree that was never published;
    /// clearing it here means that abandoned candidate cannot answer for
    /// anything before this frame stages its own, while the COMMITTED bank —
    /// the tree the App is actually routing — is never touched.
    pub fn beginFrame(self: *Frame) void {
        self.staged.records.clearRetainingCapacity();
        self.staged.tree = null;
        self.staged.placements.clearRetainingCapacity();
        self.staged.bands.clearRetainingCapacity();
    }

    /// Publish the staged resolution. The caller runs this at the same
    /// non-fallible point it publishes the tree, so a frame that fails after
    /// `stage` leaves the last committed routing exactly as it was.
    pub fn commit(self: *Frame) void {
        std.mem.swap(Bank, &self.staged, &self.committed);
        // The recycled bank must answer for nothing until it is staged again.
        self.staged.tree = null;
        self.staged.placements.clearRetainingCapacity();
        self.staged.bands.clearRetainingCapacity();
    }

    /// Stage every registered record against THIS frame's laid-out geometry:
    /// move the content roots, impose their clips, and tag each placed
    /// subtree with the band it will paint in. Call it after layout and before
    /// any custom element hook, so every later stage reads the placed boxes,
    /// and finalize the bands before the tree is published. A failure after
    /// this leaves the committed routing and its metadata untouched.
    ///
    /// Only the placement is resolved here: the BAND BASE is not known until
    /// `finalizePaintOrder`, because it starts above the application maximum
    /// and every custom record has already added its own bump by then. A
    /// node is therefore tagged with the record and the key, never with a
    /// layer of its own.
    pub fn stage(self: *Frame, tree: *widget.WidgetTree, viewport: widget.Rect) Error!void {
        if (!validRect(viewport)) return error.InvalidGeometry;
        if (self.staged.records.items.len > std.math.maxInt(u32)) return error.InvalidGeometry;
        const bank = &self.staged;
        bank.tree = null;
        bank.placements.clearRetainingCapacity();
        errdefer bank.tree = null;
        try bank.placements.ensureTotalCapacity(self.gpa, bank.records.items.len);
        // One band entry per registered record, indexed by registration
        // index, so finalize and the dormant pass below resolve without
        // allocating. Every RETAINED entry restarts from zero: a resolution
        // staged again without a beginFrame must not measure against the
        // previous one's spans, nor inherit its idea of what placed.
        try bank.bands.resize(self.gpa, bank.records.items.len);
        for (bank.bands.items) |*band| {
            band.* = .{ .span = 0, .layer = 0, .placed = false, .root = FrameNodeId.root };
        }
        // The band AND the dormant marker belong to THIS resolution: nothing
        // keeps what an earlier resolution against the same tree wrote. Both
        // are cleared before the first record is read, so the visibility
        // decision below is made on AUTHORED visibility alone and can never
        // read back this frame's own exclusions as hidden content.
        for (tree.nodes.items) |*node| {
            node.placement_paint = null;
            node.overlay_dormant = false;
        }
        for (bank.records.items, 0..) |record, index| {
            // The content root is what makes this record a claim on a node, so
            // it is resolved once here and the per-node pass below compares
            // ids. A record whose content this frame did not publish names
            // nothing, and `.root` never matches a node.
            const published = tree.frameNode(record.content);
            bank.bands.items[index].root = published orelse FrameNodeId.root;
            const content = published orelse continue;
            // An imposed clip belongs to the PLACEMENT, not to the node, so
            // staging a record REPLACES whatever an earlier resolution left on
            // its content root — even when this record resolves to nothing. A
            // `.window_escape` record can never inherit a stale inherited
            // clip, and two frames resolving the same root cannot accumulate
            // one. The field is frame-local, exactly like the moved origin
            // below, and is only published with the tree it was written into.
            const content_node = tree.node(content) orelse continue;
            content_node.placement_clip = null;
            const anchor = tree.frameNode(record.anchor) orelse continue;
            if (!widget.isVisible(tree, anchor) or !widget.isVisible(tree, content)) continue;
            const anchor_rect = widget.visualBorderRect(tree, anchor);
            const content_rect = widget.visualBorderRect(tree, content);
            if (!validRect(anchor_rect) or !validRect(content_rect)) return error.InvalidGeometry;
            if (content_rect.w == 0 or content_rect.h == 0) continue;
            const fitted = fit(anchor_rect, content_rect, viewport, record);
            if (!validRect(fitted)) return error.InvalidGeometry;
            // The clip is the tree's own rule, not a second derivation. An
            // inherited clip is IMPOSED on the content root: the box keeps its
            // laid-out SIZE and only its origin moves, and every consumer that
            // clips a node — paint, hit and inspection — reads the same
            // `placement_clip`. A placement the clip empties is not placed at
            // all: it keeps its flow box and the tree's own chain.
            if (record.clip == .inherit) {
                if (anchorClip(tree, anchor)) |clip| {
                    if (widget.clipRectToRect(fitted, clip).w <= 0) continue;
                    content_node.placement_clip = clip;
                }
            }
            try widget.moveVisualOrigin(tree, content, .{ fitted.x, fitted.y });
            const order = (@as(u64, record.priority) << 32) | @as(u64, @intCast(index));
            bank.placements.appendAssumeCapacity(.{
                .record = record,
                .rect = fitted,
                .record_index = @intCast(index),
                .order = order,
            });
            bank.bands.items[index].placed = true;
            // Post-order storage is reversed to visit each parent before its
            // children, so every node in the subtree is tagged the same way.
            var n = tree.nodes.items.len;
            while (n > 0) {
                n -= 1;
                const node = &tree.nodes.items[n];
                if (!descendsFrom(tree, node.id, content)) continue;
                if (!widget.isVisible(tree, node.id)) continue;
                // ARGMAX over the (priority, registration) key — the SAME
                // comparator hit routing uses. A nested popup registered
                // FIRST keeps its own higher band when a lower-priority
                // ancestor places around it later, and a later-registered
                // ancestor never overwrites the stronger claim.
                if (node.placement_paint) |existing| {
                    if (existing.order > order) continue;
                }
                node.placement_paint = .{
                    .record_index = @intCast(index),
                    .layer = 0,
                    .order = order,
                };
            }
        }
        // DORMANT CONTENT, one pass over the nodes. A registered record that
        // resolved to nothing — no anchor in the tree, an invisible anchor or
        // content, an empty box, a clip that emptied it — leaves its content
        // laid out, filled and authored visible with nothing placing it.
        // Painting or hitting that would show and route a popup the consumer
        // dismissed, so those nodes are marked BY VALUE here and every ordinary
        // paint and hit walk skips them.
        //
        // The records naming a node are exactly the content roots on its own
        // ancestor chain, so the chain is walked from the node upwards and the
        // FIRST root found is the DEEPEST claim: the most specific statement
        // the consumer made about that content, and the one that decides. That
        // is what hides a nested unplaced record inside a placed ancestor at
        // ANY priority, and what shows a nested PLACED record inside a dormant
        // one — where a placed, hittable and enabled subtree is what the frame
        // actually drew. The comparison is a `(priority, registration)`-free
        // DEPTH comparison on purpose: an outer popup's priority orders bands,
        // it does not decide whether the content inside it is on screen.
        //
        // A frame whose every record placed has nothing to hide, and the reset
        // above already left every marker clear, so the walk below — the only
        // pass that costs a chain walk per node — never runs.
        var unplaced = false;
        for (bank.bands.items) |band| {
            if (!band.placed) {
                unplaced = true;
                break;
            }
        }
        if (unplaced) {
            for (tree.nodes.items) |*node| {
                var verdict: ?bool = null;
                var current = node.id;
                var remaining = tree.nodes.items.len;
                while (verdict == null and current != .root and remaining > 0) : (remaining -= 1) {
                    for (bank.bands.items) |band| {
                        if (band.root != current) continue;
                        verdict = !band.placed;
                        break;
                    }
                    current = (tree.nodeConst(current) orelse break).parent;
                }
                node.overlay_dormant = verdict orelse false;
                if (node.overlay_dormant) node.placement_paint = null;
            }
        }
        bank.tree = tree;
    }

    /// Resolve the paint bands of a staged tree: every placed subtree gets a
    /// DISJOINT band above the application's own highest layer, ascending in
    /// the same (priority, registration) key hit routing uses.
    ///
    /// Call it after every element hook and before any GPU record: a custom
    /// record's own bump is part of the maximum a band must clear, and the
    /// scene reads the bands while it records. Every addition is checked —
    /// a band that would run past the end of the layer space fails the frame
    /// instead of clamping onto a layer that means something else — and a
    /// failure leaves the committed routing and its metadata as they were.
    pub fn finalizePaintOrder(self: *Frame, tree: *widget.WidgetTree) Error!void {
        const staged = self.staged.tree orelse return error.OverlayFrameNotAttached;
        if (staged != @as(*const widget.WidgetTree, tree)) return error.OverlayFrameNotAttached;
        const bank = &self.staged;
        errdefer bank.tree = null;
        // Sorting the placements puts the band assignment in hit order, so
        // the topmost popup is the topmost band whichever order the records
        // registered in.
        std.mem.sort(Placement, bank.placements.items, {}, orderLessThan);
        // One node pass measures every band, so a node's band is an indexed
        // read instead of a search through the placements.
        for (tree.nodes.items) |node| {
            const tagged = node.placement_paint orelse continue;
            const band = &bank.bands.items[tagged.record_index];
            band.span = @max(band.span, try widget.emittedLocalLayer(&node));
        }
        var next = std.math.add(u32, try widget.maximumPaintLayer(tree), 1) catch
            return error.PaintLayerOverflow;
        for (bank.placements.items, 0..) |entry, index| {
            const band = &bank.bands.items[entry.record_index];
            band.layer = next;
            // The last band's unused successor needs no layer of its own:
            // nothing paints above it.
            if (index + 1 == bank.placements.items.len) continue;
            const span = std.math.add(u32, band.span, 1) catch
                return error.PaintLayerOverflow;
            next = std.math.add(u32, next, span) catch
                return error.PaintLayerOverflow;
        }
        // One node pass publishes the bases. The metadata is stored BY VALUE
        // on the node, so the tree published here — and the one before it —
        // keep answering for their own popups with no bank left to consult.
        for (tree.nodes.items) |*node| {
            if (node.placement_paint) |*tagged| {
                tagged.layer = bank.bands.items[tagged.record_index].layer;
            }
        }
    }

    /// Stage, finalize and commit in one call, for a caller that owns its
    /// whole frame. The App uses the three steps separately, because element
    /// hooks run between staging and finalizing.
    pub fn resolve(self: *Frame, tree: *widget.WidgetTree, viewport: widget.Rect) Error!void {
        try self.stage(tree, viewport);
        try self.finalizePaintOrder(tree);
        self.commit();
    }

    pub fn placement(self: *const Frame, tree: *const widget.WidgetTree, content: WidgetId) ?Placement {
        const bank = self.bankForTree(tree) orelse return null;
        for (bank.placements.items) |entry| {
            if (entry.record.content.eql(content)) return entry;
        }
        return null;
    }

    /// Whether any REGISTERED record names this node, placed or not. This is
    /// the frame's own question — "is this overlay content?" — and the
    /// EXCLUSION is the node's `overlay_dormant` flag, which `stage` wrote
    /// into this tree: an unplaced record's content is laid out and visible
    /// and is excluded from ordinary paint and hit, while a placed one keeps
    /// its band. A tree that was never staged answers from the records alone.
    pub fn isOverlayNode(self: *const Frame, tree: *const widget.WidgetTree, id: FrameNodeId) bool {
        const bank = self.bankForTree(tree) orelse return false;
        for (bank.records.items) |record| {
            const root = tree.frameNode(record.content) orelse continue;
            if (descendsFrom(tree, id, root)) return true;
        }
        return false;
    }

    /// The topmost placed node at `point`.
    ///
    /// Ranked by the SAME key the painter ranks by, read from the SAME place:
    /// `WidgetNode.placement_paint.order`, which `finalizePaintOrder` turned
    /// into the disjoint band `widget.effectiveLayer` adds. Hit order and
    /// paint order are therefore one ordering by construction, not two lists
    /// kept in step by convention.
    ///
    /// Ranking is per NODE, never per placement. A placed subtree is painted
    /// from its own nodes' boxes, so a child laid out outside its content
    /// root's box — overflow `visible`, a negative offset — paints in its
    /// band's layer like any other node. Gating the placement on
    /// `Placement.rect`, a box the painter never consults, let exactly that
    /// child lose input to a lower-band popup drawn beneath it.
    ///
    /// Ties keep the first node forward post-order reaches, so the deepest
    /// node inside one band wins — the same answer `input.hitTest` gives.
    pub fn hitTest(self: *const Frame, tree: *const widget.WidgetTree, point: [2]f32) ?FrameNodeId {
        // Placements resolved for another tree answer for nothing: the node
        // ids they tagged are meaningless in this one.
        if (self.bankForTree(tree) == null) return null;
        var best: ?FrameNodeId = null;
        var best_order: u64 = 0;
        for (tree.nodes.items) |node| {
            const band = node.placement_paint orelse continue;
            if (best != null and band.order <= best_order) continue;
            if (!widget.isVisible(tree, node.id)) continue;
            if (node.overlay_dormant) continue;
            if (!inside(widget.visualBorderRect(tree, node.id), point)) continue;
            if (!widget.pointInClipChain(tree, node.id, point)) continue;
            best = node.id;
            best_order = band.order;
        }
        return best;
    }

    /// The node a pointer event at `point` must be delivered to: this frame's
    /// topmost content, else the tree's own hit test. `hitTest` answers
    /// placements alone; this is the routing answer, and with no placement
    /// covering the point it is exactly `input.hitTest`, so a frame that
    /// resolved nothing changes no behaviour.
    ///
    /// Both sides of a press/release identity check must use it. A press that
    /// lands on placed content still compares against the release hit, so if
    /// only one side is routed the comparison fails and the press silently
    /// activates nothing.
    pub fn hitTestTotal(
        self: *const Frame,
        tree: *const widget.WidgetTree,
        point: [2]f32,
    ) ?FrameNodeId {
        // Placements resolved for another tree answer for nothing: the node
        // ids they name are meaningless in this one.
        if (self.bankForTree(tree) == null) return input.hitTest(tree, point);
        if (self.hitTest(tree, point)) |hit| return hit;
        return input.hitTest(tree, point);
    }

    /// The node pointer routing reaches at `point` that a press can act on:
    /// the nearest actionable ancestor of the routed node, resolved INSIDE
    /// the placement that owns it.
    ///
    /// The bound is what makes this agree with paint. A popup's content root
    /// is where its band begins, so a walk that leaves it reaches content the
    /// frame painted OVER — an application button underneath would be named,
    /// and `App` would activate it from a press that landed on the popup.
    /// Within the bound the walk is unchanged, so a popup that is itself a
    /// button still answers for the label inside it, and a nested popup
    /// answers for itself rather than for the popup it sits in.
    pub fn hitActionableTotal(
        self: *const Frame,
        tree: *const widget.WidgetTree,
        point: [2]f32,
    ) ?FrameNodeId {
        const routed = self.hitTestTotal(tree, point) orelse return null;
        if (!input.isEnabled(tree, routed)) return null;
        // Null for ordinary application content, which no placement owns: the
        // walk then covers the whole tree, exactly as `input.hitActionable`
        // does, because `current == bound` is never true for `bound == null`.
        const bound = bandBound(tree, routed);
        var current = routed;
        var remaining = tree.nodes.items.len;
        while (current != .root and remaining > 0) : (remaining -= 1) {
            const node = tree.nodeConst(current) orelse return null;
            if (node.kind == .button or node.kind == .checkbox or
                node.kind == .switch_control or node.kind == .radio)
            {
                return current;
            }
            if (current == bound) return null;
            current = node.parent;
        }
        return null;
    }

    /// The stable handle pointer routing reaches at `point`: the nearest
    /// keyed ancestor of the routed node, over the same start node and the
    /// same bounded walk as `hitActionableTotal`.
    ///
    /// A dismissed popup's stable node is never the answer. It is published to
    /// no accessibility client and painted nowhere, so no press and no
    /// accessibility action can address it; and because the walk cannot leave
    /// the placement, it cannot name a handle in the content the popup covers
    /// either.
    pub fn hitStableTotal(
        self: *const Frame,
        tree: *const widget.WidgetTree,
        point: [2]f32,
    ) ?WidgetId {
        const routed = self.hitTestTotal(tree, point) orelse return null;
        if (!input.isEnabled(tree, routed)) return null;
        const bound = bandBound(tree, routed);
        var current = routed;
        var remaining = tree.nodes.items.len;
        while (current != .root and remaining > 0) : (remaining -= 1) {
            const node = tree.nodeConst(current) orelse return null;
            if (node.widget_id) |id| return id;
            if (current == bound) return null;
            current = node.parent;
        }
        return null;
    }
};

/// Stable prior focus is stored outside a frame; `set` validates its live generation.
pub const ModalFocus = struct {
    previous: ?WidgetId = null,
    content: ?WidgetId = null,

    pub fn open(
        self: *ModalFocus,
        manager: *focus.Manager,
        tree: *const widget.WidgetTree,
        content: WidgetId,
        observer: ?focus.Observer,
    ) bool {
        if (self.content != null) return false;
        const previous = manager.current;
        if (!manager.set(tree, content, observer)) return false;
        self.previous = previous;
        self.content = content;
        return true;
    }

    pub fn close(
        self: *ModalFocus,
        manager: *focus.Manager,
        tree: *const widget.WidgetTree,
        observer: ?focus.Observer,
    ) void {
        const content = self.content orelse return;
        self.content = null;
        const prior = self.previous;
        self.previous = null;
        if (prior) |target| {
            if (manager.set(tree, target, observer)) return;
        }
        const current = manager.current orelse return;
        const current_node = tree.frameNode(current) orelse {
            manager.blur(observer);
            return;
        };
        const modal_node = tree.frameNode(content) orelse {
            manager.blur(observer);
            return;
        };
        if (descendsFrom(tree, current_node, modal_node)) manager.blur(observer);
    }
};

/// Ascending (priority, registration): the order hit routing scans and the
/// order the bands are handed out in.
fn orderLessThan(_: void, first: Placement, second: Placement) bool {
    return first.order < second.order;
}

/// The content root of the placement that PAINTED `id`: the highest ancestor
/// carrying `id`'s own band. Null when `id` is ordinary application content,
/// which no placement owns — the caller then walks the whole tree, exactly as
/// `input.hitActionable` and `input.hitStable` do.
///
/// Read from the node rather than from a placement list, so the bound a
/// routing walk stops at is the same subtree the painter draws in one band.
/// Orders are unique per record, so a nested placement always carries a
/// different one and this walk cannot run past its own content root into a
/// popup the node merely sits inside.
fn bandBound(tree: *const widget.WidgetTree, id: FrameNodeId) ?FrameNodeId {
    const node = tree.nodeConst(id) orelse return null;
    const band = node.placement_paint orelse return null;
    var bound = id;
    var current = node.parent;
    var remaining = tree.nodes.items.len;
    while (current != .root and remaining > 0) : (remaining -= 1) {
        const ancestor = tree.nodeConst(current) orelse break;
        const tagged = ancestor.placement_paint orelse break;
        if (tagged.order != band.order) break;
        bound = current;
        current = ancestor.parent;
    }
    return bound;
}

fn fit(anchor: widget.Rect, content: widget.Rect, viewport: widget.Rect, record: Record) widget.Rect {
    const min_x = viewport.x + record.margin;
    const min_y = viewport.y + record.margin;
    const max_x = viewport.x + viewport.w - record.margin;
    const max_y = viewport.y + viewport.h - record.margin;
    const gap = record.gap;
    const positive = switch (record.side) {
        .below => anchor.y + anchor.h + gap,
        .above => anchor.y - content.h - gap,
        .right => anchor.x + anchor.w + gap,
        .left => anchor.x - content.w - gap,
    };
    const negative = switch (record.side) {
        .below => anchor.y - content.h - gap,
        .above => anchor.y + anchor.h + gap,
        .right => anchor.x - content.w - gap,
        .left => anchor.x + anchor.w + gap,
    };
    const first_room: f32 = switch (record.side) {
        .below => max_y - positive,
        .above => anchor.y - gap - min_y,
        .right => max_x - positive,
        .left => anchor.x - gap - min_x,
    };
    const other_room: f32 = switch (record.side) {
        .below => anchor.y - gap - min_y,
        .above => max_y - negative,
        .right => anchor.x - gap - min_x,
        .left => max_x - negative,
    };
    const extent = switch (record.side) {
        .below, .above => content.h,
        .right, .left => content.w,
    };
    const main = if (first_room < extent and other_room > first_room) negative else positive;
    const aligned = switch (record.side) {
        .below, .above => widget.Rect{ .x = anchor.x, .y = main, .w = content.w, .h = content.h },
        .right, .left => widget.Rect{ .x = main, .y = anchor.y, .w = content.w, .h = content.h },
    };
    return .{
        .x = std.math.clamp(aligned.x, min_x, @max(min_x, max_x - aligned.w)),
        .y = std.math.clamp(aligned.y, min_y, @max(min_y, max_y - aligned.h)),
        .w = aligned.w,
        .h = aligned.h,
    };
}

fn validRect(rect: widget.Rect) bool {
    return std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and
        std.math.isFinite(rect.w) and std.math.isFinite(rect.h) and
        rect.w >= 0 and rect.h >= 0 and
        std.math.isFinite(rect.x + rect.w) and std.math.isFinite(rect.y + rect.h);
}
fn inside(rect: widget.Rect, point: [2]f32) bool {
    return point[0] >= rect.x and point[0] < rect.x + rect.w and
        point[1] >= rect.y and point[1] < rect.y + rect.h;
}
fn intersect(first: widget.ClipRect, second: widget.ClipRect) widget.ClipRect {
    const x = intersectAxis(first.x, first.w, second.x, second.w);
    const y = intersectAxis(first.y, first.h, second.y, second.h);
    return .{ .x = x.start, .y = y.start, .w = x.extent, .h = y.extent };
}
fn intersectAxis(a: f32, a_len: f32, b: f32, b_len: f32) struct { start: f32, extent: f32 } {
    if (a_len == widget.ClipRect.disabled_extent) return .{ .start = b, .extent = b_len };
    if (b_len == widget.ClipRect.disabled_extent) return .{ .start = a, .extent = a_len };
    const start = @max(a, b);
    return .{ .start = start, .extent = @max(0, @min(a + a_len, b + b_len) - start) };
}

/// The clip the anchor's own clipping ancestors impose, read from the tree.
/// This is placement INPUT, not a second clipping rule: the resolved popup is
/// clipped by shrinking its box and turning on its content clip, so paint and
/// hit keep reading the tree's single chain.
fn anchorClip(tree: *const widget.WidgetTree, anchor: FrameNodeId) ?widget.ClipRect {
    var current = anchor;
    var remaining = tree.nodes.items.len;
    var clip: ?widget.ClipRect = null;
    while (current != .root and remaining > 0) : (remaining -= 1) {
        const node = tree.nodeConst(current) orelse break;
        const axes = node.contentClipAxes();
        if (axes.any()) {
            const rect = widget.ClipRect.fromRect(widget.visualBorderRect(tree, current), axes);
            clip = if (clip) |existing| intersect(existing, rect) else rect;
        }
        current = node.parent;
    }
    return clip;
}
fn descendsFrom(tree: *const widget.WidgetTree, child: FrameNodeId, root: FrameNodeId) bool {
    var current = child;
    var remaining = tree.nodes.items.len;
    while (current != .root and remaining > 0) : (remaining -= 1) {
        if (current == root) return true;
        current = (tree.nodeConst(current) orelse return false).parent;
    }
    return false;
}
