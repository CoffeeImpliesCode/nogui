// sort.comp.slang — CS1: the stable LSD radix sort of the drawable bag
// (v1 spec §3). The CPU may submit the bag in ANY order; this pass
// establishes the paint order by sorting the permutation on the 64-bit
// key (z << 32) | order:
//   - z     = the layer key (the high 32 bits; the SORT KEY)
//   - order = the submission counter (the low 32 bits; the tiebreaker)
// A stable LSD radix on the key's 8 bytes (4 passes on the order bytes
// first, then 4 on the z bytes) restores the paint order from ANY bag
// layout: on the paint-ordered bag it is the identity permutation; on a
// reversed bag the order passes re-establish the submission sequence and
// the z passes then layer it. This is the correctness contract — an
// unstable sort would scramble same-layer drawables and break the golden.
//
// Dispatch structure (one u64 push = the BDA of a SortParams entry; the
// batch writes one entry per dispatch into a host-visible params array —
// the mandelbrot compute precedent):
//   mode 0  identity   (1 dispatch):  perm_a[i] = i
//   mode 1  histogram  (8 dispatches, one per key byte): each workgroup
//           counts its 256 elements' digit into a group-local histogram
//           and stores it at hist_bda[group*256 + bucket] (no atomics,
//           no zeroing — every group owns its own 256 entries).
//   mode 2  scatter    (8 dispatches): each group computes the GLOBAL
//           per-bucket totals (redundantly in every group — deterministic)
//           and the exclusive prefix of its own bucket via a serial
//           per-thread loop (thread b owns bucket b; no shared-memory
//           scan — a barrier-in-loop scan deadlocks this driver), then
//           fills the buckets in element order through a shared staging
//           array (stability = the fill iterates the group's elements in
//           ascending order).
//   Dispatch boundaries provide the cross-group sync (Vulkan queue
//   ordering); only workgroup-scope barriers are used inside.
//
// Buffers (per-frame ring ×3, indexed by the frame):
//   bag_bda    host-visible SceneRect array (112 B records, 1 per drawable)
//   perm_a/b   device-local u32 permutation ping-pong; pass 7 ends in A
//   hist_bda   device-local scratch: groups × 256 u32
// SortParams layout MUST match SortParams in render_9slice.zig (48 B).

struct SortParams {
    uint64_t bag_bda;   // @0  the drawable bag
    uint64_t perm_a_bda;// @8  permutation A (identity input, final result)
    uint64_t perm_b_bda;// @16 permutation B (the ping-pong target)
    uint64_t hist_bda;  // @24 per-group histogram scratch (groups × 256 u32)
    uint count;         // @32 drawable count
    uint mode;          // @36 0 identity, 1 histogram, 2 scatter
    uint pass;          // @40 the key byte (0..7; 0-3 = order, 4-7 = z)
};

struct PushData {
    uint64_t params_bda;
};

[[vk::push_constant]] PushData pc;

static const uint BUCKETS = 256; // one radix digit = 8 bits
static const uint GROUP = 256;   // threads per workgroup (one element each)

// The bag record — byte layout MUST match SceneRect in
// render_9slice.zig (112 B: 104 B of fields + the implicit pad to the
// 16-aligned stride, verified against the CPU @offsetOf via SPIR-V
// OpMemberDecorate). All loads are naturally aligned.
struct SceneRect {
    float4 dst;           // 0
    float4 src;           // 16
    float4 corners;       // 32
    float4 color;         // 48
    float4 curve;         // 64
    uint material_index;  // 80
    uint clip_id;         // 84
    uint z;               // 88  the layer key
    uint origin_x;        // 92
    uint origin_y;        // 96
    uint tex_idx;         // 100
    uint order;           // 104 the submission counter (the tiebreaker)
    // implicit pad to 112
};

// The radix digit for pass p: the low 4 passes read the ORDER bytes (the
// LSD of the 64-bit key), the high 4 read the Z bytes.
uint digitOf(SceneRect r, uint pass) {
    return (pass < 4u)
        ? ((r.order >> (8u * pass)) & 0xFFu)
        : ((r.z >> (8u * (pass - 4u))) & 0xFFu);
}

groupshared uint sh[BUCKETS]; // group histogram -> inclusive scan
groupshared uint gt[BUCKETS]; // global bucket totals -> inclusive scan
groupshared uint stage[GROUP]; // this group's elements in order (scatter)
groupshared uint digits[GROUP]; // their radix digit for this pass

[shader("compute")]
[numthreads(256, 1, 1)]
void main(uint3 dtid : SV_DispatchThreadID, uint gid : SV_GroupID, uint gtid : SV_GroupThreadID) {
    SortParams p = vk::BufferPointer<SortParams>(pc.params_bda).Get();
    const uint N = p.count;
    const uint groups = (N + GROUP - 1u) / GROUP;
    // Ping-pong: even passes read A, odd passes read B (identity wrote A).
    const uint64_t cur = ((p.pass & 1u) == 0u) ? p.perm_a_bda : p.perm_b_bda;
    const uint64_t nxt = ((p.pass & 1u) == 0u) ? p.perm_b_bda : p.perm_a_bda;
    const uint64_t bag = p.bag_bda;
    const uint i = gid * GROUP + gtid; // this thread's element slot

    if (p.mode == 0u) {
        // Identity: perm_a[i] = i — the input order of pass 0.
        if (i < N) vk::BufferPointer<uint>(cur + 4u * i).Get() = i;
        return;
    }

    if (p.mode == 1u) {
        // Histogram: the group's elements -> hist_bda[gid*256 + b].
        sh[gtid] = 0u;
        GroupMemoryBarrierWithGroupSync();
        if (i < N) {
            const uint idx = vk::BufferPointer<uint>(cur + 4u * i).Get();
            SceneRect r = vk::BufferPointer<SceneRect>(bag + 112u * uint64_t(idx)).Get();
            InterlockedAdd(sh[digitOf(r, p.pass)], 1u);
        }
        GroupMemoryBarrierWithGroupSync();
        vk::BufferPointer<uint>(p.hist_bda + 4u * (gid * BUCKETS + gtid)).Get() = sh[gtid];
        return;
    }

    // ── Scatter ────────────────────────────────────────────────────────
    // Thread b (b == gtid) computes the GLOBAL totals for bucket b and the
    // count of bucket-b elements in EARLIER groups. Identical in every
    // group — deterministic, no cross-group communication needed.
    uint total_b = 0u;
    uint before_b = 0u;
    for (uint g2 = 0u; g2 < groups; g2++) {
        const uint v = vk::BufferPointer<uint>(p.hist_bda + 4u * (g2 * BUCKETS + gtid)).Get();
        total_b += v;
        if (g2 < gid) before_b += v;
    }
    gt[gtid] = total_b;
    GroupMemoryBarrierWithGroupSync();
    // The exclusive prefix of bucket b — a serial per-thread loop, NOT a
    // shared-memory scan: the fill below only needs thread b's OWN
    // bucket, and a Hillis-Steele scan with barriers inside its loop
    // hangs/device-losts this driver (NVIDIA 1660 Ti — verified with a
    // minimal probe: the loop-carried barrier deadlocks the GPU). The
    // serial prefix reads the totals written above (barriered once) and
    // never writes — race-free by construction.
    uint excl_b = 0u;
    for (uint b2 = 0u; b2 < gtid; b2++) excl_b += gt[b2];

    // Stage this group's elements in order (the scatter's stability: the
    // fill below walks them in ascending t). Unstaged tail slots carry a
    // sentinel digit (256 > any real 8-bit digit) so the fill skips them.
    if (i < N) {
        const uint idx = vk::BufferPointer<uint>(cur + 4u * i).Get();
        stage[gtid] = idx;
        digits[gtid] = digitOf(vk::BufferPointer<SceneRect>(bag + 112u * uint64_t(idx)).Get(), p.pass);
    } else {
        stage[gtid] = 0xFFFFFFFFu;
        digits[gtid] = BUCKETS; // never equals a real digit
    }
    GroupMemoryBarrierWithGroupSync();

    // Thread b owns bucket b: walk the staged elements in order and write
    // each match to its slot: excl_b (the global exclusive prefix of
    // bucket b) + before_b (the group's bucket-b range) + k (the running
    // in-bucket rank, ascending in element order — the stability).
    const uint b = gtid;
    const uint group_base = excl_b + before_b;
    uint k = 0u;
    for (uint t = 0u; t < GROUP; t++) {
        if (digits[t] == b) {
            vk::BufferPointer<uint>(nxt + 4u * (group_base + k)).Get() = stage[t];
            k++;
        }
    }
}
