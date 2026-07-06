const std = @import("std");

const c = @import("c");

const Bsp = @import("bspfile.zig");
const MAXLIGHTMAPS = Bsp.MAXLIGHTMAPS;
const parseEntities = Bsp.parseEntities;
const mathlib = @import("mathlib.zig");
const dotProduct = mathlib.dotProduct;
const vectorNormalize = mathlib.vectorNormalize;
const vectorLength = mathlib.vectorLength;
const ON_EPSILON = mathlib.ON_EPSILON;
const EQUAL_EPSILON = mathlib.EQUAL_EPSILON;
const vectorCompare = mathlib.vectorCompare;
const vectorAvg = mathlib.vectorAvg;
const crossProduct = mathlib.crossProduct;
const Vec3 = mathlib.Vec3;
const qError = @import("cmdlib.zig").qError;
const r_avertexnormals = @import("anorms.zig").r_avertexnormals;

const vec3_origin: Vec3 = .{ 0, 0, 0 };

const MAX_POINTS_ON_WINDING = 128;
const MAX_MAP_NODES = 32767;
const MAX_MAP_LEAFS = 8192;
const MAX_MAP_FACES = 65535;
const MAX_MAP_EDGES = 256000;
const MAX_PATCHES = 65536;
const TEX_SPECIAL = 1;
const SINGLEMAP = 18 * 18 * 4;
const MAX_TRI_POINTS = 2048;
const MAX_TRI_EDGES = MAX_TRI_POINTS * 6;
const MAX_TRI_TRIS = MAX_TRI_POINTS * 2;
const DIRECT_SCALE = 0.1;
const ANGLE_UP = -1;
const ANGLE_DOWN = -2;
const TRANSFER_SCALE = (1.0 / @as(f32, 16384));
const INVERSE_TRANSFER_SCALE = 16384;
const MAX_TEXLIGHTS = 128;

fn makeBackplanes(allocator: std.mem.Allocator, bsp: *const Bsp) ![]Bsp.Plane {
    const backplanes = try allocator.alloc(Bsp.Plane, bsp.planes.len);
    for (bsp.planes, 0..) |plane, i| {
        backplanes[i] = .{
            .normal = .{
                -plane.normal[0],
                -plane.normal[1],
                -plane.normal[2],
            },
            .dist = -plane.dist,
            .type = 0,
        };
    }
    return backplanes;
}

fn makeParents(state: *State, bsp: *const Bsp, nodenum: i32, parent: i32) void {
    state.nodeparents[@intCast(nodenum)] = parent;
    const node = bsp.nodes[@intCast(nodenum)];

    for (0..2) |i| {
        const j = node.children[i];
        if (j < 0)
            state.leafparents[@intCast(-j - 1)] = nodenum
        else
            makeParents(state, bsp, j, nodenum);
    }
}

pub const TNode = struct {
    type: i32 = 0,
    normal: [3]f32 = @splat(0),
    dist: f32 = 0,
    children: [2]i32 = @splat(0),
    pad: i32 = 0,
};

fn makeTNodes(allocator: std.mem.Allocator, bsp: *const Bsp) ![]TNode {
    const tnodes = try allocator.alloc(TNode, bsp.nodes.len + 1);
    @memset(tnodes, .{});

    var next: usize = 0;
    makeTNode(tnodes, bsp, 0, &next);

    return tnodes;
}

fn makeTNode(tnodes: []TNode, bsp: *const Bsp, nodenum: usize, next: *usize) void {
    const t_index = next.*;
    next.* += 1;

    const t = &tnodes[t_index];
    const node = bsp.nodes[nodenum];
    const plane = bsp.planes[@intCast(node.planenum)];

    t.type = plane.type;
    t.normal = plane.normal;
    t.dist = plane.dist;

    for (0..2) |i| {
        const child = node.children[i];

        if (child < 0) {
            const leaf_index: usize = @intCast(-child - 1);
            t.children[i] = bsp.leafs[leaf_index].contents;
        } else {
            const child_index: usize = @intCast(child);

            t.children[i] = @intCast(next.*);

            makeTNode(tnodes, bsp, child_index, next);
        }
    }
}

fn entityForModel(entities: []Bsp.Entity, modnum: usize) *Bsp.Entity {
    var buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "*{d}", .{modnum}) catch unreachable;

    for (entities) |*entity| {
        const s = entity.valueForKey("model") orelse continue;
        if (std.mem.eql(u8, s, name)) {
            return entity;
        }
    }

    return &entities[0];
}

const Winding = std.ArrayList(Vec3);

fn removeColinearPoints(allocator: std.mem.Allocator, winding: *Winding) !void {
    const old_len = winding.items.len;
    if (old_len < 3) return;

    var out = Winding.empty;
    defer out.deinit(allocator);

    try out.ensureTotalCapacity(allocator, old_len);

    var i: usize = 0;
    while (i < old_len) : (i += 1) {
        const j = (i + 1) % old_len;
        const k = (i + old_len - 1) % old_len;

        var v1 = winding.items[j] - winding.items[i];
        var v2 = winding.items[i] - winding.items[k];

        v1 = vectorNormalize(v1);
        v2 = vectorNormalize(v2);

        if (dotProduct(v1, v2) < 1.0 - ON_EPSILON) {
            try out.append(allocator, winding.items[i]);
        }
    }

    if (out.items.len == old_len) return;

    winding.clearRetainingCapacity();
    try winding.appendSlice(allocator, out.items);
}

fn windingFromFace(
    allocator: std.mem.Allocator,
    bsp: *const Bsp,
    face: *align(1) const Bsp.Face,
) !Winding {
    var winding = Winding.empty;

    for (0..face.numedges) |i| {
        const surfedge = bsp.surfedges[@intCast(face.firstedge + i)];
        const vertex = if (surfedge < 0)
            bsp.edges[@intCast(-surfedge)].v[1]
        else
            bsp.edges[@intCast(surfedge)].v[0];

        try winding.append(allocator, bsp.vertexes[@intCast(vertex)].point);
    }

    try removeColinearPoints(allocator, &winding);

    return winding;
}

fn isSky(bsp: *const Bsp, face: Bsp.Face) bool {
    const texinfo = bsp.texinfo[@intCast(face.texinfo)];
    const miptex_index: usize = @intCast(texinfo.miptex);

    const dataofs_ptr: [*]align(1) const i32 =
        @ptrCast(bsp.texdata.ptr + @sizeOf(Bsp.MiptexLump));
    const miptex_offset: usize = @intCast(dataofs_ptr[miptex_index]);

    const miptex: *align(1) const Bsp.Miptex =
        @ptrCast(bsp.texdata.ptr + miptex_offset);

    return std.ascii.startsWithIgnoreCase(&miptex.name, "sky");
}

fn crossProductSlice(a: *const [3]f32, b: *const [3]f32) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn windingArea(winding: *const Winding) f32 {
    if (winding.items.len < 3) return 0;

    const origin = winding.items[0];

    var total: f32 = 0;

    for (winding.items[2..], 2..) |p, i| {
        const d1 = winding.items[i - 1] - origin;
        const d2 = p - origin;

        const cross = crossProduct(d1, d2);

        total += 0.5 * vectorLength(cross);
    }

    return total;
}

fn windingCenter(winding: *const Winding) Vec3 {
    var center: Vec3 = .{ 0, 0, 0 };
    for (winding.items) |point| {
        center += point;
    }

    center *= @splat(1.0 / @as(f32, @floatFromInt(winding.items.len)));

    return center;
}

fn windingBounds(winding: *const Winding) struct { Vec3, Vec3 } {
    var mins: Vec3 = @splat(99999);
    var maxs: Vec3 = @splat(-99999);

    for (winding.items) |point| {
        mins = @min(mins, point);
        maxs = @max(maxs, point);
    }

    return .{ mins, maxs };
}

fn lightForTexture(state: *State, name: [16]u8) Vec3 {
    const name_trimmed = std.mem.sliceTo(&name, 0);
    for (state.texlights) |texlight| {
        const tex_name_trimmed = std.mem.sliceTo(&texlight.name, 0);
        if (std.ascii.eqlIgnoreCase(name_trimmed, tex_name_trimmed)) {
            return texlight.value;
        }
    }

    return .{ 0, 0, 0 };
}

fn baseLightForFace(state: *State, bsp: *const Bsp, face: *const Bsp.Face) Vec3 {
    const texinfo = bsp.texinfo[@intCast(face.texinfo)];
    const miptex_index: usize = @intCast(texinfo.miptex);

    const dataofs_ptr: [*]align(1) const i32 =
        @ptrCast(bsp.texdata.ptr + @sizeOf(Bsp.MiptexLump));
    const miptex_offset: usize = @intCast(dataofs_ptr[miptex_index]);

    const miptex: *align(1) const Bsp.Miptex =
        @ptrCast(bsp.texdata.ptr + miptex_offset);

    return lightForTexture(state, miptex.name);
}

pub const Transfer = struct {
    patch: u16,
    transfer: u16,
};

pub const Patch = struct {
    winding: Winding = .empty,
    mins: Vec3 = @splat(0),
    maxs: Vec3 = @splat(0),
    face_mins: Vec3 = @splat(0),
    face_maxs: Vec3 = @splat(0),
    transfers: []Transfer = &.{},
    origin: Vec3 = @splat(0),
    normal: Vec3 = @splat(0),
    plane: *align(1) const Bsp.Plane = undefined,
    chop: f32 = 0,
    scale: [2]f32 = @splat(0),
    sky: bool = false,
    totallight: Vec3 = @splat(0),
    baselight: Vec3 = @splat(0),
    directlight: Vec3 = @splat(0),
    area: f32 = 0,
    reflectivity: Vec3 = @splat(0),
    samplelight: Vec3 = @splat(0),
    samples: i32 = 0,
    faceNumber: i32 = 0,
};

fn makePatchForFace(
    state: *State,
    bsp: *const Bsp,
    face_num: usize,
    winding: Winding,
    totalarea: *f32,
) ?Patch {
    const face = bsp.faces[face_num];

    if (isSky(bsp, face)) return null;

    const texinfo = bsp.texinfo[@intCast(face.texinfo)];

    const area = windingArea(&winding);
    totalarea.* += area;

    var patch: Patch = .{};

    if (state.texscale) {
        for (0..2) |i| {
            patch.scale[i] = 0.0;

            for (0..3) |j| {
                patch.scale[i] += texinfo.vecs[i][j] * texinfo.vecs[i][j];
            }

            patch.scale[i] = @sqrt(patch.scale[i]);
        }
    } else {
        patch.scale = @splat(1.0);
    }

    patch.area = area;
    patch.chop = state.maxchop / @as(f32, @floatFromInt(@as(i32, @intFromFloat((patch.scale[0] + patch.scale[1]) / 2))));
    patch.sky = false;
    patch.winding = winding;

    patch.plane = if (face.side != 0) &state.backplanes[@intCast(face.planenum)] else &bsp.planes[@intCast(face.planenum)];

    var centroid: Vec3 = .{ 0, 0, 0 };

    for (0..@intCast(face.numedges)) |j| {
        const surfedge = bsp.surfedges[@intCast(face.firstedge + j)];

        if (surfedge > 0) {
            const edge = bsp.edges[@intCast(surfedge)];

            centroid += bsp.vertexes[edge.v[0]].point;
            centroid += bsp.vertexes[edge.v[1]].point;
        } else {
            const edge = bsp.edges[@intCast(-surfedge)];

            centroid += bsp.vertexes[edge.v[0]].point;
            centroid += bsp.vertexes[edge.v[1]].point;
        }
    }

    centroid *= @splat(1.0 / (@as(f32, @floatFromInt(face.numedges)) * 2.0));

    state.face_centroids[face_num] = centroid;

    patch.faceNumber = @intCast(face_num);
    patch.origin = windingCenter(&winding);

    patch.normal = patch.plane.normal;
    patch.origin += patch.normal;

    patch.face_mins, patch.face_maxs = windingBounds(&winding);

    patch.mins = patch.face_mins;
    patch.maxs = patch.face_maxs;

    const light = baseLightForFace(state, bsp, &face);
    patch.totallight = light;
    patch.baselight = light;

    if (!vectorCompare(light, vec3_origin)) {
        patch.chop = if (state.extra)
            state.minchop / 2
        else
            state.minchop;
    }

    return patch;
}

fn makePatches(
    allocator: std.mem.Allocator,
    state: *State,
    bsp: *const Bsp,
) !std.ArrayList(Patch) {
    var patches = std.ArrayList(Patch).empty;
    var totalarea: f32 = 0;

    state.print("{d} faces\n", .{bsp.faces.len});

    for (bsp.models, 0..) |model, i| {
        const entity = entityForModel(state.entities, i);

        var origin: Vec3 = .{ 0.0, 0.0, 0.0 };

        if (entity.valueForKey("origin")) |s| {
            var v1: f64 = undefined;
            var v2: f64 = undefined;
            var v3: f64 = undefined;
            if (c.sscanf(s, "%lf %lf %lf", &v1, &v2, &v3) == 3) {
                origin[0] = @floatCast(v1);
                origin[1] = @floatCast(v2);
                origin[2] = @floatCast(v3);
            }
        }

        for (0..@intCast(model.numfaces)) |j| {
            const face_num = @as(usize, @intCast(model.firstface)) + j;
            try state.face_entity.put(allocator, face_num, entity);
            state.face_offset[face_num] = origin;
            const face = &bsp.faces[face_num];
            var winding = try windingFromFace(allocator, bsp, face);
            for (winding.items) |*point| {
                point.* += origin;
            }

            if (patches.items.len >= MAX_PATCHES)
                return qError("num_patches == MAX_PATCHES", .{}, error.MaxPatches);

            const patch = makePatchForFace(state, bsp, face_num, winding, &totalarea) orelse {
                winding.deinit(allocator);
                continue;
            };

            try patches.append(allocator, patch);

            const face_patches = (try state.face_patches.getOrPutValue(allocator, face_num, std.ArrayList(usize).empty)).value_ptr;
            try face_patches.append(allocator, patches.items.len - 1);
        }
    }

    state.print("{d} square feet [{d:.2} square inches]\n", .{ @as(i32, @intFromFloat(totalarea / 144)), totalarea });

    return patches;
}

const EdgeShare = struct {
    faces: [2]?*align(1) const Bsp.Face = .{ null, null },
    interface_normal: Vec3 = @splat(0.0),
    coplanar: bool = false,
};

fn pairEdges(state: *State, bsp: *const Bsp) void {
    for (bsp.faces) |*face| {
        for (0..@intCast(face.numedges)) |j| {
            const surfedge = bsp.surfedges[@intCast(face.firstedge + j)];
            const e = if (surfedge < 0)
                &state.edgeshare[@intCast(-surfedge)]
            else
                &state.edgeshare[@intCast(surfedge)];

            if (surfedge < 0) {
                e.faces[1] = face;
            } else {
                e.faces[0] = face;
            }

            if (e.faces[0] != null and e.faces[1] != null) {
                if (e.faces[0].?.planenum == e.faces[1].?.planenum) {
                    e.coplanar = true;
                } else if (state.smoothing_threshold > 0) {
                    var normals: [2]Vec3 = undefined;
                    for (0..2) |n| {
                        normals[n] = bsp.planes[@intCast(e.faces[n].?.planenum)].normal;
                        if (e.faces[n].?.side != 0)
                            normals[n] = -normals[n];
                    }
                    const cos_normals_angle = dotProduct(normals[0], normals[1]);
                    if (cos_normals_angle >= state.smoothing_threshold) {
                        e.interface_normal = vectorNormalize(normals[0] + normals[1]);
                    }
                }
            }
        }
    }
}

const Side = enum { front, back, on };

/// Clips and allocates two new windings while freeing old winding
/// Differs from halflife polylib clipwinding - errors if front or back is 0
fn clipWinding(
    allocator: std.mem.Allocator,
    in: *Winding,
    normal: Vec3,
    dist: f32,
) !struct { Winding, Winding } {
    const n = in.items.len;
    var dists = [_]f32{0} ** (MAX_POINTS_ON_WINDING + 4);
    var sides = [_]Side{.on} ** (MAX_POINTS_ON_WINDING + 4);
    var counts = [3]usize{ 0, 0, 0 };

    for (in.items, 0..) |p, i| {
        const d = dotProduct(p, normal) - dist;
        dists[i] = d;
        const side: Side = if (d > ON_EPSILON) .front else if (d < -ON_EPSILON) .back else .on;
        sides[i] = side;
        counts[@intFromEnum(side)] += 1;
    }
    sides[n] = sides[0];
    dists[n] = dists[0];

    if (counts[@intFromEnum(Side.front)] == 0) {
        return error.ClipWindingAllBack;
    }
    if (counts[@intFromEnum(Side.back)] == 0) {
        return error.ClipWindingAllFront;
    }

    const maxpts = n + 4;
    var f = try Winding.initCapacity(allocator, maxpts);
    var b = try Winding.initCapacity(allocator, maxpts);

    for (0..n) |i| {
        const p1 = in.items[i];

        switch (sides[i]) {
            .on => {
                try f.append(allocator, p1);
                try b.append(allocator, p1);
                continue;
            },
            .front => try f.append(allocator, p1),
            .back => try b.append(allocator, p1),
        }

        if (sides[i + 1] == .on or sides[i + 1] == sides[i])
            continue;

        // generate a split point
        const p2 = in.items[(i + 1) % n];
        const d = dists[i] / (dists[i] - dists[i + 1]);

        var mid: Vec3 = undefined;
        inline for (0..3) |j| {
            if (normal[j] == 1.0)
                mid[j] = dist
            else if (normal[j] == -1.0)
                mid[j] = -dist
            else
                mid[j] = p1[j] + d * (p2[j] - p1[j]);
        }

        try f.append(allocator, mid);
        try b.append(allocator, mid);
    }

    if (f.items.len > maxpts or b.items.len > maxpts)
        return qError("ClipWinding: points exceed estimate", .{}, error.ClipWindingPointsExceededEstimate);
    if (f.items.len > MAX_POINTS_ON_WINDING or b.items.len > MAX_POINTS_ON_WINDING)
        return qError("ClipWinding: MAX_POINTS_ON_WINDING", .{}, error.ClipWindingTooManyPoints);

    in.deinit(allocator);

    return .{ f, b };
}

fn subdividePatch(allocator: std.mem.Allocator, state: *State, patch_index: usize) !void {
    var patch = &state.patches.items[patch_index];

    const total = patch.maxs - patch.mins;

    var widest: f32 = -1;
    var widest_axis: usize = 0;
    var subdivide_it = false;

    inline for (0..3) |i| {
        if (total[i] > widest) {
            widest_axis = i;
            widest = total[i];
        }
        if (total[i] > patch.chop or
            ((patch.face_maxs[i] == patch.maxs[i] or patch.face_mins[i] == patch.mins[i]) and
                total[i] > state.minchop))
        {
            subdivide_it = true;
        }
    }

    if (!subdivide_it) return;

    if (state.patches.items.len == MAX_PATCHES)
        return qError("MAX_PATCHES", .{}, error.MaxPatches);

    var split = vec3_origin;
    const dist = switch (widest_axis) {
        0 => blk: {
            split[0] = 1;
            break :blk (patch.mins[0] + patch.maxs[0]) * 0.5;
        },
        1 => blk: {
            split[1] = 1;
            break :blk (patch.mins[1] + patch.maxs[1]) * 0.5;
        },
        2 => blk: {
            split[2] = 1;
            break :blk (patch.mins[2] + patch.maxs[2]) * 0.5;
        },
        else => unreachable,
    };

    const o1, const o2 = try clipWinding(allocator, &state.patches.items[patch_index].winding, split, dist);

    var newp: Patch = .{
        .winding = o2,
        .face_mins = patch.face_mins,
        .face_maxs = patch.face_maxs,
        .normal = patch.plane.normal,
        .plane = patch.plane,
        .chop = patch.chop,
        .sky = patch.sky,
        .totallight = patch.totallight,
        .baselight = patch.baselight,
        .directlight = patch.directlight,
        .reflectivity = patch.reflectivity,
        .faceNumber = patch.faceNumber,
    };

    patch.winding = o1;

    patch.area = windingArea(&patch.winding);
    newp.area = windingArea(&newp.winding);

    patch.origin = windingCenter(&patch.winding);
    newp.origin = windingCenter(&newp.winding);

    patch.origin += patch.normal;
    newp.origin += newp.normal;

    patch.mins, patch.maxs = windingBounds(&patch.winding);
    newp.mins, newp.maxs = windingBounds(&newp.winding);

    try state.patches.append(allocator, newp);
    const newp_index = state.patches.items.len - 1;

    const face_patches = (try state.face_patches.getOrPutValue(allocator, @intCast(newp.faceNumber), std.ArrayList(usize).empty)).value_ptr;
    try face_patches.append(allocator, newp_index);

    // re-get patch because appending may invalidate pointer
    patch = &state.patches.items[patch_index];

    // Edge hack for patch
    const patch_total = patch.maxs - patch.mins;
    if (patch_total[0] < patch.chop and patch_total[1] < patch.chop and
        patch_total[2] < patch.chop)
    {
        inline for (0..3) |i| {
            if ((patch.face_maxs[i] == patch.maxs[i] or patch.face_mins[i] ==
                patch.mins[i]) and patch_total[i] > state.minchop)
            {
                patch.chop = @max(state.minchop, patch.chop / 2);
                break;
            }
        }
    }
    try subdividePatch(allocator, state, patch_index);

    // Edge hack for newp
    const np2 = &state.patches.items[newp_index];
    const np_total = np2.maxs - np2.mins;
    if (np_total[0] < np2.chop and np_total[1] < np2.chop and np_total[2] < np2.chop) {
        inline for (0..3) |i| {
            if ((np2.face_maxs[i] == np2.maxs[i] or np2.face_mins[i] == np2.mins[i]) and
                np_total[i] > state.minchop)
            {
                np2.chop = @max(state.minchop, np2.chop / 2);
                break;
            }
        }
    }
    try subdividePatch(allocator, state, newp_index);
}

fn subdividePatches(allocator: std.mem.Allocator, state: *State) !void {
    const num = state.patches.items.len;
    for (0..num) |i| {
        try subdividePatch(allocator, state, i);
    }
    state.print("{d} patches after subdivision\n", .{state.patches.items.len});
}

const EmitType = enum {
    surface,
    point,
    spotlight,
    skylight,
};

const DirectLight = struct {
    type: EmitType = .surface,
    style: i32 = 0,
    origin: Vec3 = @splat(0),
    intensity: Vec3 = @splat(0),
    normal: Vec3 = @splat(0),
    stopdot: f32 = 0,
    stopdot2: f32 = 0,
};

fn pointInLeaf(bsp: *const Bsp, point: Vec3) *align(1) const Bsp.Leaf {
    var nodenum: i32 = 0;
    while (nodenum >= 0) {
        const node = bsp.nodes[@intCast(nodenum)];
        const plane = bsp.planes[@intCast(node.planenum)];
        const d = dotProduct(point, plane.normal) - plane.dist;
        nodenum = if (d > 0) node.children[0] else node.children[1];
    }
    return &bsp.leafs[@intCast(-nodenum - 1)];
}

const LeafDirectLightMap = std.AutoHashMapUnmanaged(*align(1) const Bsp.Leaf, std.ArrayList(DirectLight));

fn createDirectLights(
    allocator: std.mem.Allocator,
    state: *State,
    bsp: *const Bsp,
) !LeafDirectLightMap {
    var lights_map = LeafDirectLightMap.empty;

    var numdlights: usize = 0;

    // surfaces
    for (state.patches.items) |*p| {
        if (vectorAvg(p.totallight) >= state.dlight_threshold) {
            numdlights += 1;
            const leaf = pointInLeaf(bsp, p.origin);

            const leaf_direct_lights = (try lights_map.getOrPutValue(allocator, leaf, std.ArrayList(DirectLight).empty)).value_ptr;

            try leaf_direct_lights.append(allocator, .{
                .type = .surface,
                .style = 0,
                .origin = p.origin,
                .normal = p.normal,
                .intensity = p.totallight * @as(Vec3, @splat(p.area * DIRECT_SCALE)),
                .stopdot = 0,
                .stopdot2 = 0,
            });
        }
        p.totallight = @splat(0);
    }

    // entities
    for (state.entities) |*e| {
        const classname = e.valueForKey("classname") orelse continue;
        if (!std.mem.startsWith(u8, classname, "light"))
            continue;

        numdlights += 1;

        const origin = e.vectorForKey("origin");

        const leaf = pointInLeaf(bsp, origin);

        const leaf_direct_lights = (try lights_map.getOrPutValue(allocator, leaf, std.ArrayList(DirectLight).empty)).value_ptr;

        const dl = try leaf_direct_lights.addOne(allocator);
        dl.* = .{};
        dl.origin = origin;

        dl.style = @trunc(e.floatForKey("style"));

        // parse _light value
        var r: f64 = 0;
        var g: f64 = 0;
        var b: f64 = 0;
        var scaler: f64 = 0;
        const plight = e.valueForKey("_light") orelse "";
        const arg_cnt = c.sscanf(plight.ptr, "%lf %lf %lf %lf", &r, &g, &b, &scaler);

        switch (arg_cnt) {
            1 => {
                dl.intensity = @splat(@floatCast(r));
            },
            3 => {
                dl.intensity = .{ @floatCast(r), @floatCast(g), @floatCast(b) };
            },
            4 => {
                dl.intensity = .{
                    @as(f32, @floatCast(r)) / 255.0 * @as(f32, @floatCast(scaler)),
                    @as(f32, @floatCast(g)) / 255.0 * @as(f32, @floatCast(scaler)),
                    @as(f32, @floatCast(b)) / 255.0 * @as(f32, @floatCast(scaler)),
                };
            },
            else => {
                std.debug.print("entity at ({d},{d},{d}) has bad '_light' value: '{s}'\n", .{
                    origin[0], origin[1], origin[2], plight,
                });
                continue;
            },
        }

        const target = e.valueForKey("target") orelse "";

        if (std.mem.eql(u8, classname, "light_spot") or
            std.mem.eql(u8, classname, "light_environment") or
            target.len > 0)
        {
            if (vectorAvg(dl.intensity) == 0)
                dl.intensity = @splat(500);

            dl.type = .spotlight;

            dl.stopdot = e.floatForKey("_cone");
            if (dl.stopdot == 0) dl.stopdot = 10;

            dl.stopdot2 = e.floatForKey("_cone2");
            if (dl.stopdot2 == 0) dl.stopdot2 = dl.stopdot;

            if (dl.stopdot2 < dl.stopdot) dl.stopdot2 = dl.stopdot;
            dl.stopdot2 = @cos(dl.stopdot2 / 180.0 * std.math.pi);
            dl.stopdot = @cos(dl.stopdot / 180.0 * std.math.pi);

            if (target.len > 0) {
                // point towards target
                if (findTargetEntity(state.entities, target)) |e2| {
                    const dest = e2.vectorForKey("origin");
                    dl.normal = vectorNormalize(dest - dl.origin);
                } else {
                    std.debug.print("WARNING: light at ({d} {d} {d}) has missing target\n", .{
                        @as(i32, @trunc(origin[0])),
                        @as(i32, @trunc(origin[1])),
                        @as(i32, @trunc(origin[2])),
                    });
                }
            } else {
                const angles = e.vectorForKey("angles");

                var angle = e.floatForKey("angle");
                if (angle == ANGLE_UP) {
                    dl.normal = .{ 0, 0, 1 };
                } else if (angle == ANGLE_DOWN) {
                    dl.normal = .{ 0, 0, -1 };
                } else {
                    if (angle == 0) angle = angles[1];
                    dl.normal = .{
                        @cos(angle / 180.0 * std.math.pi),
                        @sin(angle / 180.0 * std.math.pi),
                        0,
                    };
                }

                var pitch = e.floatForKey("pitch");
                if (pitch == 0) pitch = angles[0];

                dl.normal[2] = @sin(pitch / 180.0 * std.math.pi);
                dl.normal[0] *= @cos(pitch / 180.0 * std.math.pi);
                dl.normal[1] *= @cos(pitch / 180.0 * std.math.pi);
            }

            if (e.floatForKey("_sky") != 0 or std.mem.eql(u8, classname, "light_environment")) {
                dl.type = .skylight;
                dl.stopdot2 = e.floatForKey("_sky");
            }
        } else {
            if (vectorAvg(dl.intensity) == 0)
                dl.intensity = @splat(300);
            dl.type = .point;
        }

        if (dl.type != .skylight) {
            const l1 = @max(dl.intensity[0], dl.intensity[1], dl.intensity[2]);
            const l1sq = l1 * l1 / 10.0;
            dl.intensity *= @splat(l1sq);
        }
    }

    state.print("{d} direct lights\n", .{numdlights});
    return lights_map;
}

fn findTargetEntity(entities: []Bsp.Entity, target: []const u8) ?*Bsp.Entity {
    for (entities) |*e| {
        const t = e.valueForKey("targetname") orelse continue;
        if (std.mem.eql(u8, t, target)) return e;
    }
    return null;
}

pub const LightInfo = struct {
    // lightmaps: [MAXLIGHTMAPS][SINGLEMAP]Vec3,
    // numlightstyles: usize = 0,
    // light: ?*f32 = null,
    facedist: f32 = 0,
    facenormal: Vec3 = @splat(0),

    numsurfpt: usize = 0,
    surfpt: [SINGLEMAP]Vec3 = @splat(@as(Vec3, @splat(0))),
    // facemid: Vec3 = @splat(0),

    texorg: Vec3 = @splat(0),
    worldtotex: [2]Vec3 = @splat(@as(Vec3, @splat(0))),
    textoworld: [2]Vec3 = @splat(@as(Vec3, @splat(0))),

    exactmins: [2]f32 = @splat(0),
    exactmaxs: [2]f32 = @splat(0),

    texmins: [2]i32 = @splat(0),
    texsize: [2]i32 = @splat(0),
    // lightstyles: [256]i32 = @splat(0),

    surfnum: usize,
    face: *align(1) Bsp.Face,
};

fn calcFaceVectors(bsp: *const Bsp, l: *LightInfo) !void {
    const texinfo = bsp.texinfo[@intCast(l.face.texinfo)];
    inline for (0..2) |i| {
        inline for (0..3) |j| {
            l.worldtotex[i][j] = texinfo.vecs[i][j];
        }
    }

    var texnormal = vectorNormalize(crossProductSlice(texinfo.vecs[1][0..3], texinfo.vecs[0][0..3]));

    var distscale = dotProduct(texnormal, l.facenormal);
    if (distscale == 0)
        return qError("Texture axis perpendicular to face", .{}, error.TextureAxisPerpToFace);

    if (distscale < 0) {
        distscale = -distscale;
        texnormal = -texnormal;
    }

    distscale = 1 / distscale;

    for (0..2) |i| {
        const len = vectorLength(l.worldtotex[i]);
        var dist = dotProduct(l.worldtotex[i], l.facenormal);
        dist *= distscale;
        l.textoworld[i] = (l.worldtotex[i] - texnormal * @as(Vec3, @splat(dist))) * @as(Vec3, @splat((1.0 / len) * (1.0 / len)));
    }

    l.texorg =
        -l.textoworld[0] * @as(Vec3, @splat(texinfo.vecs[0][3])) -
        l.textoworld[1] * @as(Vec3, @splat(texinfo.vecs[1][3]));

    var dist = dotProduct(l.texorg, l.facenormal) - l.facedist - 1.0;
    dist *= distscale;
    l.texorg += texnormal * @as(Vec3, @splat(-dist));
}

fn calcFaceExtents(bsp: *const Bsp, l: *LightInfo) !void {
    const face = l.face;

    var mins: [2]f32 = @splat(999999);
    var maxs: [2]f32 = @splat(-99999);

    const texinfo = &bsp.texinfo[@intCast(face.texinfo)];

    for (0..face.numedges) |i| {
        const surfedge = bsp.surfedges[face.firstedge + i];
        const v = if (surfedge >= 0)
            bsp.vertexes[@intCast(bsp.edges[@intCast(surfedge)].v[0])]
        else
            bsp.vertexes[@intCast(bsp.edges[@intCast(-surfedge)].v[1])];

        for (0..2) |j| {
            const val =
                v.point[0] * texinfo.vecs[j][0] +
                v.point[1] * texinfo.vecs[j][1] +
                v.point[2] * texinfo.vecs[j][2] +
                texinfo.vecs[j][3];
            if (val < mins[j])
                mins[j] = val;
            if (val > maxs[j])
                maxs[j] = val;
        }
    }

    for (0..2) |i| {
        l.exactmins[i] = mins[i];
        l.exactmaxs[i] = maxs[i];

        mins[i] = @floor(mins[i] / 16.0);
        maxs[i] = @ceil(maxs[i] / 16.0);

        l.texmins[i] = @trunc(mins[i]);
        l.texsize[i] = @trunc(maxs[i] - mins[i]);
        if (l.texsize[i] > 17)
            return qError("Bad surface extents", .{}, error.BadSurfaceExtents);
    }
}

fn calcPoints(state: *State, bsp: *const Bsp, l: *LightInfo) void {
    const mids = (l.exactmaxs[0] + l.exactmins[0]) * 0.5;
    const midt = (l.exactmaxs[1] + l.exactmins[1]) * 0.5;

    // l.facemid =
    //     l.texorg +
    //     l.textoworld[0] * @as(Vec3, @splat(mids)) +
    //     l.textoworld[1] * @as(Vec3, @splat(midt));

    const h: usize = @intCast(l.texsize[1] + 1);
    const w: usize = @intCast(l.texsize[0] + 1);

    const starts = @as(f32, @floatFromInt(l.texmins[0])) * 16.0;
    const startt = @as(f32, @floatFromInt(l.texmins[1])) * 16.0;

    const step: f32 = 16.0;

    l.numsurfpt = w * h;

    const origin = state.face_offset[l.surfnum];

    for (0..h) |t| {
        for (0..w) |s| {
            var us = starts + @as(f32, @floatFromInt(s)) * step;
            var ut = startt + @as(f32, @floatFromInt(t)) * step;

            for (0..64) |i| {
                const idx = t * w + s;

                l.surfpt[idx] =
                    l.texorg +
                    l.textoworld[0] * @as(Vec3, @splat(us)) +
                    l.textoworld[1] * @as(Vec3, @splat(ut)) +
                    origin;

                const luxelleaf = pointInLeaf(bsp, l.surfpt[idx]);

                if (luxelleaf != &bsp.leafs[0]) break;

                if ((i & 1) != 0) {
                    if (us > mids) {
                        us -= 8.0;
                        if (us < mids)
                            us = mids;
                    } else {
                        us += 8.0;
                        if (us > mids)
                            us = mids;
                    }
                } else {
                    if (ut > midt) {
                        ut -= 8.0;
                        if (ut < midt)
                            ut = midt;
                    } else {
                        ut += 8.0;
                        if (ut > midt)
                            ut = midt;
                    }
                }
            }
        }
    }
}

fn decompressVis(bsp: *const Bsp, in_ptr: [*]const u8, decompressed: [*]u8) void {
    const row = (bsp.leafs.len + 7) >> 3;
    var in = in_ptr;
    var out = decompressed;

    while (@intFromPtr(out) - @intFromPtr(decompressed) < row) {
        if (in[0] != 0) {
            out[0] = in[0];
            out += 1;
            in += 1;
            continue;
        }

        var count = in[1];
        in += 2;
        while (count > 0) : (count -= 1) {
            out[0] = 0;
            out += 1;
        }
    }
}

fn getPhongNormal(state: *State, bsp: *const Bsp, facenum: usize, spot: Vec3) Vec3 {
    const face = &bsp.faces[facenum];
    const plane = &bsp.planes[@intCast(face.planenum)];
    var facenormal = plane.normal;
    if (face.side != 0)
        facenormal = .{
            -facenormal[0],
            -facenormal[1],
            -facenormal[2],
        };

    var phongnormal = facenormal;

    if (state.smoothing_threshold != 0) {
        const numedges: usize = face.numedges;
        const firstedge: usize = face.firstedge;

        for (0..numedges) |j| {
            const e = bsp.surfedges[firstedge + j];
            // Original qrad C indexed with `f->firstedge + ((j-1)%f->numedges)`, which would
            // evaluate to `firstedge -1 % numedges` at j = 0. `-1 % n` evaluates to -1 no matter
            // what, meaning we take `firstedge - 1` at the zeroth index. This is a bug that we
            // faithfully replicate.
            const e1 = (bsp.surfedges.ptr - 1)[firstedge + j];
            const e2 = bsp.surfedges[firstedge + ((j + 1) % numedges)];

            const es = &state.edgeshare[@intCast(@abs(e))];
            const es1 = &state.edgeshare[@intCast(@abs(e1))];
            const es2 = &state.edgeshare[@intCast(@abs(e2))];

            if ((es.coplanar and es1.coplanar and es2.coplanar) or
                (vectorCompare(es.interface_normal, vec3_origin) and
                    vectorCompare(es1.interface_normal, vec3_origin) and
                    vectorCompare(es2.interface_normal, vec3_origin)))
                continue;

            const p1: Vec3 = if (e > 0)
                bsp.vertexes[@intCast(bsp.edges[@intCast(e)].v[0])].point
            else
                bsp.vertexes[@intCast(bsp.edges[@intCast(-e)].v[1])].point;

            const p2: Vec3 = if (e > 0)
                bsp.vertexes[@intCast(bsp.edges[@intCast(e)].v[1])].point
            else
                bsp.vertexes[@intCast(bsp.edges[@intCast(-e)].v[0])].point;

            const centroid = state.face_centroids[facenum];
            const v1 = p1 - centroid;
            const v2 = p2 - centroid;
            const vspot = spot - centroid;

            const aa = dotProduct(v1, v1);
            const bb = dotProduct(v2, v2);
            const ab = dotProduct(v1, v2);
            const denom = aa * bb - ab * ab;
            if (@abs(denom) < 0.0001) continue;

            const a1 = (bb * dotProduct(v1, vspot) - ab * dotProduct(vspot, v2)) / denom;
            const a2 = (dotProduct(vspot, v2) - a1 * ab) / bb;

            if (a1 >= 0.0 and a2 >= 0.0) {
                var n1 = es.interface_normal + es1.interface_normal;
                if (vectorCompare(n1, vec3_origin))
                    n1 = facenormal;
                n1 = vectorNormalize(n1);

                var n2 = es.interface_normal + es2.interface_normal;
                if (vectorCompare(n2, vec3_origin))
                    n2 = facenormal;
                n2 = vectorNormalize(n2);

                phongnormal =
                    facenormal * @as(Vec3, @splat(1.0 - a1 - a2)) +
                    n1 * @as(Vec3, @splat(a1)) +
                    n2 * @as(Vec3, @splat(a2));
                phongnormal = vectorNormalize(phongnormal);
                break;
            }
        }
    }

    return phongnormal;
}

const PlaneType = enum(i32) {
    x = 0,
    y = 1,
    z = 2,
    any_x = 3,
    any_y = 4,
    any_z = 5,
};

const Contents = enum(i32) {
    empty = -1,
    solid = -2,
    water = -3,
    slime = -4,
    lava = -5,
    sky = -6,
    origin = -7,
    clip = -8,
    current_0 = -9,
    current_90 = -10,
    current_180 = -11,
    current_270 = -12,
    current_up = -13,
    current_down = -14,
    translucent = -15,
};

fn testLine(state: *State, node: i32, start: Vec3, stop: Vec3) Contents {
    if (node == @intFromEnum(Contents.solid)) return .solid;
    if (node == @intFromEnum(Contents.sky)) return .sky;
    if (node < 0) return .empty;

    const tnode = &state.tnodes[@intCast(node)];

    const front, const back = switch (@as(PlaneType, @enumFromInt(tnode.type))) {
        .x => .{ start[0] - tnode.dist, stop[0] - tnode.dist },
        .y => .{ start[1] - tnode.dist, stop[1] - tnode.dist },
        .z => .{ start[2] - tnode.dist, stop[2] - tnode.dist },
        else => .{
            start[0] * tnode.normal[0] + start[1] * tnode.normal[1] + start[2] * tnode.normal[2] - tnode.dist,
            stop[0] * tnode.normal[0] + stop[1] * tnode.normal[1] + stop[2] * tnode.normal[2] - tnode.dist,
        },
    };

    if (front >= -ON_EPSILON and back >= -ON_EPSILON)
        return testLine(state, tnode.children[0], start, stop);

    if (front < ON_EPSILON and back < ON_EPSILON)
        return testLine(state, tnode.children[1], start, stop);

    const side: usize = if (front < 0) 1 else 0;

    const frac = front / (front - back);
    const mid = start + (stop - start) * @as(Vec3, @splat(frac));

    const r = testLine(state, tnode.children[side], start, mid);
    if (r != .empty) return r;
    return testLine(state, tnode.children[side ^ 1], mid, stop);
}

fn vectorMaximum(v: Vec3) f32 {
    return @reduce(.Max, v);
}

pub const NUMVERTEXNORMALS = 162;
fn gatherSampleLight(
    state: *State,
    bsp: *const Bsp,
    pos: Vec3,
    pvs: []const u8,
    normal: Vec3,
    sample: *[MAXLIGHTMAPS]Vec3,
    styles: *[MAXLIGHTMAPS]u8,
) void {
    var maybe_sky_used: ?*const DirectLight = null;

    for (1..bsp.leafs.len) |i| {
        if ((pvs[(i - 1) >> 3] & (@as(u8, 1) << @intCast((i - 1) & 7))) == 0)
            continue;

        const leaf = &bsp.leafs[i];
        const lights = state.directlights.get(leaf) orelse continue;

        for (lights.items) |*l| {
            var add: Vec3 = @splat(0);

            if (l.type == .skylight) {
                if (maybe_sky_used != null) continue;
                maybe_sky_used = l;

                const dot = -dotProduct(normal, l.normal);
                if (dot <= ON_EPSILON / 10.0) continue;

                const delta = pos + l.normal * @as(Vec3, @splat(-10000));
                if (testLine(state, 0, pos, delta) != .sky) continue;

                add = l.intensity * @as(Vec3, @splat(dot));
            } else {
                var delta = l.origin - pos;
                const dist = @max(vectorLength(delta), 1.0);
                delta = vectorNormalize(delta);

                const dot = dotProduct(delta, normal);
                if (dot <= ON_EPSILON / 10.0) continue;

                switch (l.type) {
                    .point => {
                        const ratio = dot / (dist * dist);
                        add = l.intensity * @as(Vec3, @splat(ratio));
                    },
                    .surface => {
                        const dot2 = -dotProduct(delta, l.normal);
                        if (dot2 <= ON_EPSILON / 10.0) continue;
                        const ratio = dot * dot2 / (dist * dist);
                        add = l.intensity * @as(Vec3, @splat(ratio));
                    },
                    .spotlight => {
                        const dot2 = -dotProduct(delta, l.normal);
                        if (dot2 <= l.stopdot2) continue;
                        var ratio = dot * dot2 / (dist * dist);
                        if (dot2 <= l.stopdot)
                            ratio *= (dot2 - l.stopdot2) / (l.stopdot - l.stopdot2);
                        add = l.intensity * @as(Vec3, @splat(ratio));
                    },
                    .skylight => unreachable,
                }
            }

            const threshold: f32 = if (l.style != 0) state.coring else 0.0;
            if (vectorMaximum(add) <= threshold) continue;

            if (l.type != .skylight and testLine(state, 0, pos, l.origin) != .empty)
                continue;

            // find or allocate a style slot
            var style_index: usize = 0;
            for (styles, 0..) |style, index| {
                if (style == l.style or style == 255) {
                    style_index = index;
                    break;
                }
            }
            if (style_index == MAXLIGHTMAPS) {
                std.debug.print("WARNING: Too many direct light styles on a face({d},{d},{d})\n", .{
                    pos[0], pos[1], pos[2],
                });
                continue;
            }
            if (styles[style_index] == 255)
                styles[style_index] = @intCast(l.style);

            sample[style_index] += add;
        }
    }

    // indirect sunlight
    if (maybe_sky_used != null and state.indirect_sun != 0.0) {
        const sky_used = maybe_sky_used.?;
        const sky_intensity = sky_used.intensity * @as(Vec3, @splat(state.indirect_sun / @as(f32, NUMVERTEXNORMALS * 2)));
        var total: Vec3 = @splat(0);

        for (r_avertexnormals) |anorm| {
            const dot = -dotProduct(normal, anorm);
            if (dot <= ON_EPSILON / 10.0) continue;

            const delta = pos + anorm * @as(Vec3, @splat(-10000));
            if (testLine(state, 0, pos, delta) != .sky) continue;

            total += sky_intensity * @as(Vec3, @splat(dot));
        }

        if (vectorMaximum(total) > 0) {
            var style_index: usize = 0;
            for (styles, 0..) |style, index| {
                if (style == sky_used.style or style == 255) {
                    style_index = index;
                    break;
                }
            }
            if (style_index == MAXLIGHTMAPS) {
                std.debug.print("WARNING: Too many direct light styles on a face({d},{d},{d})\n", .{
                    pos[0], pos[1], pos[2],
                });
                return;
            }
            if (styles[style_index] == 255)
                styles[style_index] = @intCast(sky_used.style);

            sample[style_index] += total;
        }
    }
}

fn addSampleToPatch(state: *State, s: *const Sample, facenum: usize) void {
    if (state.numbounce == 0) return;
    if (vectorAvg(s.light) < 1) return;

    const patch_indices = state.face_patches.get(facenum) orelse return;

    for (patch_indices.items) |pi| {
        const patch = &state.patches.items[pi];

        const mins, const maxs = windingBounds(&patch.winding);

        var in_bounds = true;
        inline for (0..3) |i| {
            if (mins[i] > s.pos[i] + 16 or maxs[i] < s.pos[i] - 16) {
                in_bounds = false;
                break;
            }
        }
        if (!in_bounds) continue;

        patch.samples += 1;
        patch.samplelight += s.light;
    }
}

fn buildFacelights(allocator: std.mem.Allocator, state: *State, bsp: *const Bsp, face_num: usize) !void {
    var face = &bsp.faces[face_num];

    // resetting face light info
    face.lightofs = -1;
    face.styles = @splat(255);

    if ((bsp.texinfo[@intCast(face.texinfo)].flags & TEX_SPECIAL) != 0) return;

    // every face has style 0
    face.styles[0] = 0;

    var l: LightInfo = .{
        .surfnum = face_num,
        .face = face,
    };

    const plane = &bsp.planes[@intCast(face.planenum)];
    l.facenormal = plane.normal;
    l.facedist = plane.dist;
    if (face.side != 0) {
        l.facenormal = -l.facenormal;
        l.facedist = -l.facedist;
    }

    try calcFaceVectors(bsp, &l);
    try calcFaceExtents(bsp, &l);
    calcPoints(state, bsp, &l);

    const lightmap_width = l.texsize[0] + 1;
    const lightmap_height = l.texsize[1] + 1;

    const size = lightmap_width * lightmap_height;
    if (size > SINGLEMAP)
        return qError("Bad lightmap size", .{}, error.BadLightmapSize);

    for (&state.facelight[face_num].samples) |*samples| {
        samples.* = try allocator.alloc(Sample, l.numsurfpt);
        @memset(samples.*, .{});
    }

    var thisoffset: i32 = -1;
    var lastoffset: i32 = -1;

    // If this is defined inside the loop, it will be filled with different garabge data on
    // every loop run, being even more unpredictable (or garbage data filled with 0xAA in
    // zig's debug modes) than if we reuse the same buffer every single time. Debugging this
    // took 3 days of 8 hour work sessions. Whoever wrote the original C code, I hate :-)
    var pvs: [(MAX_MAP_LEAFS + 7) / 8]u8 = undefined;

    for (0..l.numsurfpt) |i| {
        const spot = l.surfpt[i];

        for (&state.facelight[face_num].samples) |style_samples| {
            style_samples[i].pos = spot;
        }

        if (bsp.visdata.len == 0) {
            @memset(&pvs, 255);
            lastoffset = -1;
        } else {
            const leaf = pointInLeaf(bsp, spot);
            thisoffset = leaf.visofs;
            if (i == 0 or thisoffset != lastoffset) {
                if (thisoffset == -1)
                    return qError("leaf->visofs == -1", .{}, error.LeafVisofsNegativeOne);

                decompressVis(bsp, bsp.visdata[@intCast(leaf.visofs)..].ptr, &pvs);
            }
            lastoffset = thisoffset;
        }

        var sampled: [MAXLIGHTMAPS]Vec3 = @splat(@as(Vec3, @splat(0)));

        if (state.extra) {
            const weighting = [3][3]i32{ .{ 5, 9, 5 }, .{ 9, 16, 9 }, .{ 5, 9, 5 } };
            var subsamples: i32 = 0;

            var t: i32 = -1;
            while (t <= 1) : (t += 1) {
                var s: i32 = -1;
                while (s <= 1) : (s += 1) {
                    const subsample = @as(i32, @intCast(i)) + t * lightmap_width + s;
                    const sample_s = @rem(@as(i32, @intCast(i)), lightmap_width);
                    const sample_t = @divTrunc(@as(i32, @intCast(i)), lightmap_width);

                    if (0 <= s + sample_s and s + sample_s < lightmap_width and
                        0 <= t + sample_t and t + sample_t < lightmap_height)
                    {
                        var subsampled: [MAXLIGHTMAPS]Vec3 = @splat(@as(Vec3, @splat(0)));

                        // Calculate the point one third of the way toward the "subsample point"
                        var pos = l.surfpt[i];
                        pos += l.surfpt[i];
                        pos += l.surfpt[@intCast(subsample)];
                        pos *= @splat(1.0 / 3.0);

                        const pointnormal = getPhongNormal(state, bsp, face_num, pos);
                        gatherSampleLight(state, bsp, pos, &pvs, pointnormal, &subsampled, &face.styles);

                        for (&face.styles, 0..) |style, j| {
                            if (style == 255) break;
                            subsampled[j] *= @as(Vec3, @splat(@floatFromInt(weighting[@intCast(s + 1)][@intCast(t + 1)])));
                            sampled[j] += subsampled[j];
                        }

                        subsamples += weighting[@intCast(s + 1)][@intCast(t + 1)];
                    }
                }
            }

            for (&face.styles, 0..) |style, j| {
                if (style == 255) break;
                sampled[j] *= @as(Vec3, @splat(1.0 / @as(f32, @floatFromInt(subsamples))));
            }
        } else {
            const pointnormal = getPhongNormal(state, bsp, face_num, spot);
            gatherSampleLight(state, bsp, spot, &pvs, pointnormal, &sampled, &face.styles);
        }

        for (&face.styles, 0..) |style, j| {
            if (style == 255) break;
            state.facelight[face_num].samples[j][i].light = sampled[j];
            if (style == 0) {
                addSampleToPatch(state, &state.facelight[face_num].samples[j][i], face_num);
            }
        }
    }

    // Average direct light on each patch for radiosity bounces
    if (state.numbounce > 0) {
        if (state.face_patches.get(face_num)) |list| {
            for (list.items) |patch_index| {
                const patch = &state.patches.items[patch_index];
                if (patch.samples > 0) {
                    const scale = 1.0 / @as(f32, @floatFromInt(patch.samples));
                    const v = patch.samplelight * @as(Vec3, @splat(scale));
                    patch.totallight += v;
                    patch.directlight += v;
                }
            }
        }
    }

    // TODO: ambient

    // Add baselight (emissive texture self-illumination)
    for (&face.styles, 0..) |style, j| {
        if (style == 255) break;
        if (style == 0) {
            const first_patch_idx = state.face_patches.get(face_num).?.items[0];
            const baselight = state.patches.items[first_patch_idx].baselight;
            for (0..l.numsurfpt) |i| {
                state.facelight[face_num].samples[j][i].light += baselight;
            }
            break;
        }
    }
}

fn patchPlaneDist(state: *const State, patch: *const Patch) f32 {
    return patch.plane.dist + dotProduct(state.face_offset[@intCast(patch.faceNumber)], patch.normal);
}

fn testPatchToFace(
    state: *State,
    vismatrix: []u8,
    patchnum: usize,
    facenum: usize,
    head: i32,
    bitpos: usize,
) void {
    const patch = &state.patches.items[patchnum];
    const patch2_indices = state.face_patches.get(facenum) orelse return;
    if (patch2_indices.items.len == 0) return;

    const patch2_first = &state.patches.items[patch2_indices.items[0]];

    // if emitter is behind that face plane, skip all patches
    if (dotProduct(patch.origin, patch2_first.normal) <= patchPlaneDist(state, patch2_first) + 1.01)
        return;

    for (patch2_indices.items) |pi| {
        const patch2 = &state.patches.items[pi];
        const m = pi;

        if (m > patchnum and dotProduct(patch2.origin, patch.normal) > patchPlaneDist(state, patch) + 1.01 and testLine(state, head, patch.origin, patch2.origin) == .empty) {
            const bitset = bitpos + m;
            vismatrix[bitset >> 3] |= @as(u8, 1) << @intCast(bitset & 7);
        }
    }
}

fn buildVisRow(
    state: *State,
    bsp: *const Bsp,
    vismatrix: []u8,
    patchnum: usize,
    pvs: []const u8,
    head: i32,
    bitpos: usize,
) void {
    var face_tested: [MAX_MAP_FACES]u8 = @splat(0);

    // leaf 0 is the solid leaf (skipped)
    for (1..bsp.leafs.len) |j| {
        if ((pvs[(j - 1) >> 3] & (@as(u8, 1) << @intCast((j - 1) & 7))) == 0)
            continue;

        const leaf = &bsp.leafs[j];
        for (0..leaf.nummarksurfaces) |k| {
            const l = bsp.marksurfaces[leaf.firstmarksurface + k];
            if (face_tested[l] != 0) continue;
            face_tested[l] = 1;
            testPatchToFace(state, vismatrix, patchnum, l, head, bitpos);
        }
    }
}

fn buildVisLeafs(
    state: *State,
    bsp: *const Bsp,
    vismatrix: []u8,
) void {
    var pvs: [(MAX_MAP_LEAFS + 7) / 8]u8 = undefined;

    // leaf 0 is the solid leaf (skipped)
    for (1..bsp.leafs.len) |i| {
        const srcleaf = &bsp.leafs[i];

        if (srcleaf.visofs < 0) continue;

        decompressVis(bsp, bsp.visdata[@intCast(srcleaf.visofs)..].ptr, &pvs);

        const head: i32 = 0;

        for (0..srcleaf.nummarksurfaces) |lface| {
            const facenum = bsp.marksurfaces[srcleaf.firstmarksurface + lface];
            const patch_indices = state.face_patches.get(facenum) orelse continue;

            for (patch_indices.items) |pi| {
                const patch = &state.patches.items[pi];

                const leaf = pointInLeaf(bsp, patch.origin);
                if (leaf != srcleaf) continue;

                const patchnum = pi;
                const bitpos = patchnum * state.patches.items.len - (patchnum * (patchnum + 1)) / 2;

                buildVisRow(state, bsp, vismatrix, patchnum, &pvs, head, bitpos);

                // build to bmodel faces
                if (bsp.models.len < 2) continue;
                for (@as(usize, @intCast(bsp.models[1].firstface))..bsp.faces.len) |facenum2| {
                    testPatchToFace(state, vismatrix, patchnum, facenum2, head, bitpos);
                }
            }
        }
    }
}

fn buildVisMatrix(
    allocator: std.mem.Allocator,
    state: *State,
    bsp: *const Bsp,
) ![]u8 {
    const num_patches = state.patches.items.len;
    const count = ((num_patches + 1) * (((num_patches + 1) + 15) / 16));

    state.print("visibility matrix: {d:.1} megs\n", .{@as(f32, @floatFromInt(count)) / (1024 * 1024.0)});

    const vismatrix = try allocator.alloc(u8, count);
    @memset(vismatrix, 0);

    buildVisLeafs(state, bsp, vismatrix);

    return vismatrix;
}

fn checkVisBit(vismatrix: []const u8, num_patches: usize, p1_in: usize, p2_in: usize) bool {
    const p1 = @min(p1_in, p2_in);
    const p2 = @max(p1_in, p2_in);
    const bitpos = p1 * num_patches - (p1 * (p1 + 1)) / 2 + p2;
    const shift: u3 = @intCast(bitpos & 7);
    return (vismatrix[bitpos >> 3] & (@as(u8, 1) << shift)) != 0;
}

// TODO: make each call an iteration of thread, not one call for entire thread (matching gatherLight, etc)
fn makeScales(allocator: std.mem.Allocator, state: *State, vismatrix: []const u8) !usize {
    const num_patches = state.patches.items.len;
    var total_transfer: usize = 0;

    for (state.patches.items, 0..) |*patch, i| {
        const origin = patch.origin;
        var plane = patch.plane.*;
        plane.dist = patchPlaneDist(state, patch);
        const area = patch.area;

        var transfers_buf: [MAX_PATCHES]Transfer = undefined;
        var num_transfers: usize = 0;
        var total: f32 = 0;

        for (state.patches.items, 0..) |*patch2, j| {
            if (!checkVisBit(vismatrix, num_patches, i, j)) continue;

            var delta = patch2.origin - origin;
            const dist = vectorLength(delta);
            delta = vectorNormalize(delta);

            var scale: f32 = if (!patch.sky)
                dotProduct(delta, patch.normal)
            else
                1.0;
            scale *= -dotProduct(delta, patch2.normal);

            var trans = scale / (dist * dist);
            if (trans < -ON_EPSILON) return qError("transfer < 0", .{}, error.NegativeTransfer);

            var send = trans * patch2.area;
            if (send > 0.4) {
                trans = 0.4 / patch2.area;
                send = 0.4;
            }
            total += send;

            trans = trans * area * INVERSE_TRANSFER_SCALE;
            if (trans >= 0x10000) trans = 0xffff;
            if (trans == 0) continue;

            transfers_buf[num_transfers] = .{
                .transfer = @intFromFloat(trans),
                .patch = @intCast(j),
            };
            num_transfers += 1;
            total_transfer += 1;
        }

        if (num_transfers > 0) {
            patch.transfers = try allocator.alloc(Transfer, num_transfers);
            const normalize_factor = 0.5 / total;
            for (0..num_transfers) |j| {
                patch.transfers[j] = .{
                    .transfer = @intFromFloat(std.math.clamp(
                        @as(f32, @floatFromInt(transfers_buf[j].transfer)) * normalize_factor,
                        0.0,
                        65535.0,
                    )),
                    .patch = transfers_buf[j].patch,
                };
            }
        }
    }

    return total_transfer;
}

fn makeAllScales(
    allocator: std.mem.Allocator,
    state: *State,
    bsp: *const Bsp,
) !void {
    const vismatrix = try buildVisMatrix(allocator, state, bsp);
    defer allocator.free(vismatrix);

    const total_transfer = try makeScales(allocator, state, vismatrix);

    state.print("transfer lists: {d:.1} megs\n", .{
        @as(f32, @floatFromInt(total_transfer * @sizeOf(Transfer))) / (1024 * 1024.0),
    });
}

fn swapTransfersTask(state: *State, patchnum: usize) !void {
    const patch = &state.patches.items[patchnum];
    if (patch.transfers.len == 0) return;

    for (patch.transfers) |*t| {
        const k = t.patch;
        if (k > patchnum) break;

        const patch2 = &state.patches.items[k];
        if (patch2.transfers.len == 0) {
            std.debug.print("WARNING: SwapTransfers: unmatched\n", .{});
            continue;
        }

        // binary search for match
        var l: usize = 0;
        var h: usize = patch2.transfers.len - 1;
        var found = false;
        while (l <= h) {
            const m = (l + h) >> 1;
            const n = patch2.transfers[m].patch;
            if (n < patchnum) {
                l = m + 1;
            } else if (n > patchnum) {
                if (m == 0) break;
                h = m - 1;
            } else {
                const tmp = patch2.transfers[m].transfer;
                patch2.transfers[m].transfer = t.transfer;
                t.transfer = tmp;
                found = true;
                break;
            }
        }

        if (!found) {
            return qError("Didn't match transfer", .{}, error.DidntMatchTransfer);
        }
    }
}

fn collectLight(state: *State, emitlight: []Vec3, addlight: []Vec3) Vec3 {
    var total: Vec3 = @splat(0);

    for (state.patches.items, 0..) |*patch, i| {
        if (patch.sky) {
            emitlight[i] = @splat(0);
            addlight[i] = @splat(0);
            continue;
        }

        patch.totallight += addlight[i];
        emitlight[i] = addlight[i] * @as(Vec3, @splat(TRANSFER_SCALE));
        total += emitlight[i];
        addlight[i] = @splat(0);
    }

    total *= @splat(INVERSE_TRANSFER_SCALE);
    return total;
}

fn gatherLight(state: *State, emitlight: []const Vec3, addlight: []Vec3, patch_num: usize) void {
    const patch = state.patches.items[patch_num];

    var sum: Vec3 = @splat(0);

    for (patch.transfers) |trans| {
        sum += emitlight[trans.patch] * @as(Vec3, @splat(@floatFromInt(trans.transfer)));
    }

    addlight[patch_num] = sum;
}

fn bounceLight(allocator: std.mem.Allocator, state: *State) !void {
    const num_patches = state.patches.items.len;

    const emitlight = try allocator.alloc(Vec3, num_patches);
    defer allocator.free(emitlight);
    const addlight = try allocator.alloc(Vec3, num_patches);
    defer allocator.free(addlight);

    @memset(emitlight, @splat(0));
    @memset(addlight, @splat(0));

    for (state.patches.items, 0..) |*patch, i| {
        emitlight[i] = patch.totallight * @as(Vec3, @splat(TRANSFER_SCALE));
    }

    for (0..state.numbounce) |i| {
        for (0..state.patches.items.len) |j| {
            gatherLight(state, emitlight, addlight, j);
        }

        const added = collectLight(state, emitlight, addlight);
        state.print("\tBounce #{d} added RGB({d:.0}, {d:.0}, {d:.0})\n", .{
            i + 1, added[0], added[1], added[2],
        });
    }
}

fn precompLightmapOffsets(state: *State, bsp: *const Bsp) usize {
    var lightdatasize: usize = 0;

    for (bsp.faces, 0..) |*face, face_num| {
        const facelight = state.facelight[face_num];

        if ((bsp.texinfo[@intCast(face.texinfo)].flags & TEX_SPECIAL) != 0)
            continue;

        var lightstyles: usize = 0;
        while (lightstyles < MAXLIGHTMAPS) : (lightstyles += 1) {
            if (face.styles[lightstyles] == 255) {
                break;
            }
        }

        if (lightstyles == 0) continue;

        face.lightofs = @intCast(lightdatasize);
        lightdatasize += facelight.samples[0].len * 3 * lightstyles;
    }

    return lightdatasize;
}

const TriEdge = struct {
    p0: usize,
    p1: usize,
    normal: Vec3,
    dist: f32,
    tri: ?usize,
};

const Triangle = struct {
    edges: [3]usize,
};

const EdgeMatrix = std.AutoHashMapUnmanaged(EdgePoints, usize);

const Triangulation = struct {
    plane: *align(1) const Bsp.Plane,
    edgematrix: EdgeMatrix = .empty,
    points: std.ArrayList(*Patch) = .empty,
    edges: std.ArrayList(TriEdge) = .empty,
    tris: std.ArrayList(Triangle) = .empty,

    fn addPatch(self: *Triangulation, allocator: std.mem.Allocator, patch: *Patch) !void {
        if (self.points.items.len == MAX_TRI_POINTS)
            return qError("trian->numpoints == MAX_TRI_POITNS", .{}, error.MaxTriPoints);

        try self.points.append(allocator, patch);
    }

    fn deinit(self: *Triangulation, allocator: std.mem.Allocator) void {
        self.edgematrix.deinit(allocator);
        self.points.deinit(allocator);
        self.edges.deinit(allocator);
        self.tris.deinit(allocator);
    }
};

const EdgePoints = struct {
    p0: usize,
    p1: usize,

    pub fn reversed(self: EdgePoints) EdgePoints {
        return .{
            .p0 = self.p1,
            .p1 = self.p0,
        };
    }
};

fn findEdge(allocator: std.mem.Allocator, trian: *Triangulation, points: EdgePoints) !usize {
    if (trian.edgematrix.get(points)) |index|
        return index;

    if (trian.edges.items.len > MAX_TRI_EDGES - 2)
        return qError("trian->numedges > MAX_TRI_EDGES-2", .{}, error.MaxTriEdges);

    const v1 = vectorNormalize(trian.points.items[points.p0].origin - trian.points.items[points.p1].origin);
    const normal = crossProduct(v1, trian.plane.normal);
    const dist = dotProduct(trian.points.items[points.p0].origin, normal);

    try trian.edges.append(allocator, .{
        .p0 = points.p0,
        .p1 = points.p1,
        .normal = normal,
        .dist = dist,
        .tri = null,
    });
    const e_index = trian.edges.items.len - 1;
    try trian.edgematrix.put(allocator, points, e_index);

    try trian.edges.append(allocator, .{
        .p0 = points.p1,
        .p1 = points.p0,
        .normal = -normal,
        .dist = -dist,
        .tri = null,
    });
    const be_index = trian.edges.items.len - 1;
    try trian.edgematrix.put(allocator, points.reversed(), be_index);

    return e_index;
}

fn triEdgeR(allocator: std.mem.Allocator, trian: *Triangulation, edge_index: usize) !void {
    const edge = trian.edges.items[edge_index];

    if (edge.tri != null)
        return;

    const p0 = trian.points.items[edge.p0].origin;
    const p1 = trian.points.items[edge.p1].origin;

    var best: f32 = 1.1;
    var best_point_index: usize = undefined;
    for (trian.points.items, 0..) |patch, i| {
        const point = patch.origin;

        if (dotProduct(point, edge.normal) - edge.dist < 0)
            continue;
        var v1 = p0 - point;
        var v2 = p1 - point;
        if (vectorLength(v1) == 0)
            continue;
        if (vectorLength(v2) == 0)
            continue;
        v1 = vectorNormalize(v1);
        v2 = vectorNormalize(v2);

        const angle = dotProduct(v1, v2);
        if (angle < best) {
            best = angle;
            best_point_index = i;
        }
    }

    if (best >= 1)
        return;

    const new_triangle = try trian.tris.addOne(allocator);
    const new_triangle_index = trian.tris.items.len - 1;
    new_triangle.edges[0] = edge_index;
    new_triangle.edges[1] = try findEdge(allocator, trian, .{
        .p0 = edge.p1,
        .p1 = best_point_index,
    });
    new_triangle.edges[2] = try findEdge(allocator, trian, .{
        .p0 = best_point_index,
        .p1 = edge.p0,
    });
    for (new_triangle.edges) |e|
        trian.edges.items[e].tri = new_triangle_index;

    try triEdgeR(allocator, trian, try findEdge(allocator, trian, .{
        .p0 = best_point_index,
        .p1 = edge.p1,
    }));
    try triEdgeR(allocator, trian, try findEdge(allocator, trian, .{
        .p0 = edge.p0,
        .p1 = best_point_index,
    }));
}

fn triangulatePoints(allocator: std.mem.Allocator, trian: *Triangulation) !void {
    if (trian.points.items.len < 2)
        return;

    var best_distance: f32 = 9999;
    var best_points: EdgePoints = undefined;

    for (0..trian.points.items.len) |i| {
        const p1 = trian.points.items[i].origin;

        for (i + 1..trian.points.items.len) |j| {
            const p2 = trian.points.items[j].origin;

            const v1 = p2 - p1;
            const distance = vectorLength(v1);

            if (distance < best_distance) {
                best_distance = distance;
                best_points = .{
                    .p0 = i,
                    .p1 = j,
                };
            }
        }
    }

    const e = try findEdge(allocator, trian, best_points);
    const e2 = try findEdge(allocator, trian, best_points.reversed());

    try triEdgeR(allocator, trian, e);
    try triEdgeR(allocator, trian, e2);
}

fn pointInTriangle(point: Vec3, trian: *Triangulation, tri_index: usize) bool {
    const triangle = trian.tris.items[tri_index];
    for (triangle.edges) |edge_idx| {
        const edge = trian.edges.items[edge_idx];
        const d = dotProduct(edge.normal, point) - edge.dist;
        if (d < 0)
            return false;
    }

    return true;
}

fn lerpTriangle(trian: *Triangulation, tri_index: usize, point: Vec3) Vec3 {
    const triangle = trian.tris.items[tri_index];

    const e1 = trian.edges.items[triangle.edges[0]];
    const e2 = trian.edges.items[triangle.edges[1]];
    const e3 = trian.edges.items[triangle.edges[2]];

    const p1 = trian.points.items[e1.p0];
    const p2 = trian.points.items[e2.p0];
    const p3 = trian.points.items[e3.p0];

    const base = p1.totallight;

    const d1 = p2.totallight - base;
    const d2 = p3.totallight - base;

    const x = dotProduct(point, e1.normal) - e1.dist;
    const y = dotProduct(point, e3.normal) - e3.dist;

    const y1 = dotProduct(p2.origin, e3.normal) - e3.dist;
    const x2 = dotProduct(p3.origin, e1.normal) - e1.dist;

    var result = base;

    if (@abs(x2) >= ON_EPSILON) {
        result += d2 * @as(Vec3, @splat(x / x2));
    }

    if (@abs(y1) >= ON_EPSILON) {
        result += d1 * @as(Vec3, @splat(y / y1));
    }

    return result;
}

fn sampleTriangulation(point: Vec3, trian: *Triangulation, last_tri_index: *?usize) !Vec3 {
    if (trian.points.items.len == 0) {
        return @splat(0);
    }

    if (trian.points.items.len == 1) {
        return trian.points.items[0].totallight;
    }

    if (last_tri_index.*) |index| {
        if (pointInTriangle(point, trian, index)) {
            return lerpTriangle(trian, index, point);
        }
    }

    for (0..trian.tris.items.len) |tri_index| {
        if (last_tri_index.* == tri_index)
            continue;

        if (!pointInTriangle(point, trian, tri_index))
            continue;

        last_tri_index.* = tri_index;
        return lerpTriangle(trian, tri_index, point);
    }

    for (trian.edges.items) |*edge| {
        if (edge.tri != null)
            continue;

        const d = dotProduct(point, edge.normal) - edge.dist;
        if (d < 0)
            continue;

        const p0 = trian.points.items[edge.p0];
        const p1 = trian.points.items[edge.p1];

        const v1 = vectorNormalize(p1.origin - p0.origin);
        const v2 = point - p0.origin;

        const proj = dotProduct(v2, v1);
        if (proj < 0 or proj > 1)
            continue;

        return p0.totallight + @as(Vec3, @splat(proj)) * (p1.totallight - p0.totallight);
    }

    var best: f32 = 99999;
    var p1: ?*Patch = null;

    for (trian.points.items) |p0| {
        const v1 = point - p0.origin;
        const d = vectorLength(v1);

        if (d < best) {
            best = d;
            p1 = p0;
        }
    }

    if (p1 == null)
        return qError("SampleTriangulation: no points", .{}, error.SampleTriangulationNoPoints);

    return p1.?.totallight;
}

fn finalLightFace(allocator: std.mem.Allocator, state: *State, bsp: *const Bsp, face_num: usize) !void {
    const face = &bsp.faces[face_num];
    const facelight = &state.facelight[face_num];

    if ((bsp.texinfo[@intCast(face.texinfo)].flags & TEX_SPECIAL) != 0)
        return;

    var lightstyles: usize = 0;
    while (lightstyles < MAXLIGHTMAPS) : (lightstyles += 1) {
        if (face.styles[lightstyles] == 255) {
            break;
        }
    }

    if (lightstyles == 0) return;

    var trian: *Triangulation = undefined;

    if (state.numbounce > 0) {
        trian = try allocator.create(Triangulation);

        trian.* = .{
            .plane = &bsp.planes[@intCast(face.planenum)],
        };

        if (state.face_patches.get(face_num)) |list| {
            for (list.items) |patch_index| {
                const patch = &state.patches.items[patch_index];
                try trian.addPatch(allocator, patch);
            }
        }

        for (0..face.numedges) |j| {
            const surfedge = bsp.surfedges[@as(usize, @intCast(face.firstedge)) + j];

            const es = if (surfedge > 0)
                &state.edgeshare[@intCast(surfedge)]
            else
                &state.edgeshare[@intCast(-surfedge)];

            if (!es.coplanar and vectorCompare(vec3_origin, es.interface_normal))
                continue;

            // must obtain face2 after above continue statement
            const face2 = if (surfedge > 0)
                es.faces[1].?
            else
                es.faces[0].?;

            if (state.face_patches.get(face2-bsp.faces.ptr)) |list| {
                for (list.items) |patch_index| {
                    const patch = &state.patches.items[patch_index];
                    try trian.addPatch(allocator, patch);
                }
            }
        }

        try triangulatePoints(allocator, trian);
    }

    const minlight: f32 = state.face_entity.get(face_num).?.floatForKey("_minlight") * 128;

    for (0..lightstyles) |k| {
        var last_tri: ?usize = null;
        for (facelight.samples[k], 0..) |sample, j| {
            var lb = sample.light * @as(Vec3, @splat(2.0));

            if (state.numbounce > 0 and k == 0)
                lb += try sampleTriangulation(sample.pos, trian, &last_tri);

            lb *= @splat(state.lightscale);

            lb = @max(lb, @as(Vec3, @splat(minlight)));

            const max: f32 = @reduce(.Max, lb);
            if (max > state.maxlight) {
                lb *= @splat(state.maxlight / max);
            }

            if (state.gamma != 1.0) {
                lb = @exp(@as(Vec3, @splat(state.gamma)) * @log(lb * @as(Vec3, @splat(1.0 / 256.0)))) * @as(Vec3, @splat(256.0));
            }

            const base = @as(usize, @intCast(face.lightofs)) + k * facelight.samples[0].len * 3 + j * 3;

            const clamped = @min(@max(lb, @as(Vec3, @splat(0.0))), @as(Vec3, @splat(255.0)));

            bsp.lightdata[base + 0] = @trunc(clamped[0]);
            bsp.lightdata[base + 1] = @trunc(clamped[1]);
            bsp.lightdata[base + 2] = @trunc(clamped[2]);
        }
    }

    if (state.numbounce > 0) {
        trian.deinit(allocator);
        allocator.destroy(trian);
    }
}

const TexLight = struct {
    name: [256]u8,
    value: Vec3,
    filename: []u8,
};

const Sample = struct {
    pos: Vec3 = @splat(0),
    light: Vec3 = @splat(0),
};

const Facelight = struct {
    samples: [MAXLIGHTMAPS][]Sample = [_][]Sample{&.{}} ** MAXLIGHTMAPS,
};

const FacePatchesMap = std.AutoHashMapUnmanaged(usize, std.ArrayList(usize));

pub const State = struct {
    entities: []Bsp.Entity = &.{},
    backplanes: []Bsp.Plane = &.{},
    leafparents: [MAX_MAP_LEAFS]i32 = @splat(0),
    nodeparents: [MAX_MAP_NODES]i32 = @splat(0),
    face_entity: std.AutoHashMapUnmanaged(usize, *Bsp.Entity) = .empty,
    face_offset: [MAX_MAP_FACES]Vec3 = @splat(@as(Vec3, @splat(0))),
    face_patches: FacePatchesMap = FacePatchesMap.empty,
    face_centroids: [MAX_MAP_EDGES]Vec3 = @splat(@as(Vec3, @splat(0))),
    texlights: []TexLight = &.{},
    edgeshare: [MAX_MAP_EDGES]EdgeShare = @splat(.{}),
    patches: std.ArrayList(Patch) = .empty,
    facelight: [MAX_MAP_FACES]Facelight = @splat(.{}),
    directlights: LeafDirectLightMap = .empty,
    tnodes: []TNode = &.{},

    numbounce: u32 = 1,
    maxchop: f32 = 64,
    minchop: f32 = 64,
    dumpatches: bool = false,

    ambient: Vec3 = @splat(0),
    maxlight: f32 = 256,

    lightscale: f32 = 1.0,
    dlight_threshold: f32 = 25.0,

    gamma: f32 = 0.5,
    indirect_sun: f32 = 1.0,
    extra: bool = false,
    smoothing_threshold: f32 = 0,

    coring: f32 = 1.0,
    texscale: bool = true,

    // cmdlib.h
    verbose: bool = false,

    pub fn print(self: *const State, comptime fmt: []const u8, args: anytype) void {
        if (!self.verbose) return;

        std.debug.print(fmt, args);
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.face_entity.deinit(allocator);
        for (self.texlights) |texlight| {
            allocator.free(texlight.filename);
        }
        allocator.free(self.texlights);
    }
};

pub fn radWorld(allocator: std.mem.Allocator, state: *State, bsp: *Bsp) !void {
    state.entities = try parseEntities(allocator, bsp);
    defer {
        for (state.entities) |entity| entity.deinit(allocator);
        allocator.free(state.entities);
    }

    state.backplanes = try makeBackplanes(allocator, bsp);
    defer allocator.free(state.backplanes);

    makeParents(state, bsp, 0, -1);

    state.tnodes = try makeTNodes(allocator, bsp);
    defer allocator.free(state.tnodes);

    state.patches = try makePatches(allocator, state, bsp);
    defer {
        for (state.patches.items) |*patch| patch.winding.deinit(allocator);
        state.patches.deinit(allocator);

        var it = state.face_patches.valueIterator();
        while (it.next()) |face_patches| {
            face_patches.deinit(allocator);
        }
        state.face_patches.deinit(allocator);
    }

    pairEdges(state, bsp);

    try subdividePatches(allocator, state);

    state.directlights = try createDirectLights(allocator, state, bsp);

    for (0..bsp.faces.len) |i| {
        try buildFacelights(allocator, state, bsp, i);
    }
    defer for (0..bsp.faces.len) |i| {
        for (&state.facelight[i].samples) |*samples| {
            if (samples.len > 0) allocator.free(samples.*);
            samples.* = &.{};
        }
    };

    // DeleteDirectLights
    {
        var it = state.directlights.valueIterator();
        while (it.next()) |lights| {
            lights.deinit(allocator);
        }
        state.directlights.deinit(allocator);
    }

    if (state.numbounce > 0) {
        try makeAllScales(allocator, state, bsp);

        for (0..state.patches.items.len) |i| {
            try swapTransfersTask(state, i);
        }

        try bounceLight(allocator, state);
        // free transfers
        for (state.patches.items) |*patch| {
            if (patch.transfers.len > 0) {
                allocator.free(patch.transfers);
                patch.transfers = &.{};
            }
        }

        for (state.patches.items) |*patch| {
            if (!vectorCompare(patch.directlight, vec3_origin)) {
                patch.totallight -= patch.directlight;
            }
        }
    }

    const new_lightdata_size = precompLightmapOffsets(state, bsp);

    const new_lightdata = try allocator.alloc(u8, new_lightdata_size);
    @memset(new_lightdata, 0);
    bsp.lightdata = new_lightdata;

    for (0..bsp.faces.len) |face_num| {
        try finalLightFace(allocator, state, bsp, face_num);
    }
}

pub fn readLightFile(allocator: std.mem.Allocator, io: std.Io, state: *State, filename: []const u8) !void {
    const file = std.Io.Dir.cwd().openFile(io, filename, .{ .mode = .read_only }) catch |err| {
        return qError("ERROR: Couldn't open texlight file {s}", .{filename}, err);
    };
    defer file.close(io);

    std.debug.print("[Reading texlights from '{s}']\n", .{filename});

    var texlights = std.ArrayList(TexLight).fromOwnedSlice(state.texlights);

    var scan_buf: [128]u8 = undefined;

    var file_texlights: usize = 0;

    var reader = file.reader(io, &scan_buf);
    while (try reader.interface.takeDelimiter('\n')) |line| {
        if (texlights.items.len == MAX_TEXLIGHTS)
            return qError("MAX_TEXLIGHTS", .{}, error.MaxTexlights);

        const scan = try allocator.dupeSentinel(u8, line, 0);
        defer allocator.free(scan);

        // splatting this so that the buffer is filled with 0s and can be later compared as an entire buffer. maybe we should just store strings as slices...
        var texlight: [256]u8 = @splat(0);
        var r: f32 = 1;
        var g: f32 = 1;
        var b: f32 = 1;
        var i: f32 = 1;
        const arg_count = c.sscanf(scan, "%s %f %f %f %f", &texlight, &r, &g, &b, &i);

        if (arg_count == 2) {
            g = r;
            b = r;
        } else if (arg_count == 5) {
            r *= i / 255.0;
            g *= i / 255.0;
            b *= i / 255.0;
        } else if (arg_count != 4) {
            if (scan.len > 4)
                std.debug.print("ignoring bad texlight '{s}' in {s}", .{ scan, filename });
            continue;
        }

        const new_filename = try allocator.dupe(u8, filename);

        for (texlights.items) |*existing| {
            if (std.mem.eql(u8, &texlight, &existing.name)) {
                if (std.mem.eql(u8, existing.filename, filename)) {
                    std.debug.print("ERROR\x07: Duplication of '{s}' in file '{s}'!\n", .{ existing.name, existing.filename });
                } else if (existing.value[0] != r or existing.value[1] != g or existing.value[2] != b) {
                    std.debug.print("Warning: Overriding '{s}' from '{s}' with '{s}'!\n", .{ existing.name, existing.filename, filename });
                } else {
                    std.debug.print("Warning: Redundant '{s}' def in '{s}' AND '{s}'!\n", .{ existing.name, existing.filename, filename });
                }
            }
            allocator.free(existing.filename);
            existing.value = .{ r, g, b };
            existing.filename = new_filename;
            break;
        } else {
            try texlights.append(allocator, .{
                .name = texlight,
                .value = .{ r, g, b },
                .filename = new_filename,
            });
        }
        file_texlights += 1;
    }

    state.texlights = try texlights.toOwnedSlice(allocator);

    state.print("[{d} texlights parsed from '{s}']\n\n", .{ file_texlights, filename });
}
