const std = @import("std");
const Io = std.Io;

const c = @import("c");

const ScripLib = @import("scriplib.zig");
const Vec3 = @import("mathlib.zig").Vec3;
const qError = @import("cmdlib.zig").qError;

pub const BSPVERSION = 30;

pub const LUMP_ENTITIES = 0;
pub const LUMP_PLANES = 1;
pub const LUMP_TEXTURES = 2;
pub const LUMP_VERTEXES = 3;
pub const LUMP_VISIBILITY = 4;
pub const LUMP_NODES = 5;
pub const LUMP_TEXINFO = 6;
pub const LUMP_FACES = 7;
pub const LUMP_LIGHTING = 8;
pub const LUMP_CLIPNODES = 9;
pub const LUMP_LEAFS = 10;
pub const LUMP_MARKSURFACES = 11;
pub const LUMP_EDGES = 12;
pub const LUMP_SURFEDGES = 13;
pub const LUMP_MODELS = 14;
pub const HEADER_LUMPS = 15;

pub const MAX_MAP_HULLS = 4;
pub const MAX_MAP_ENTITIES = 1024;
pub const MAXLIGHTMAPS = 4;

pub const MAX_KEY = 32;
pub const MAX_VALUE = 1024;

pub const Bsp = @This();

bytes: []const u8,

entdata: []const u8,
planes: []align(1) const Plane,
texdata: []const u8,
vertexes: []align(1) const Vertex,
visdata: []const u8,
nodes: []align(1) const Node,
texinfo: []align(1) const Texinfo,
faces: []align(1) Face,
lightdata: []u8,
clipnodes: []const u8,
leafs: []align(1) const Leaf,
marksurfaces: []align(1) const u16,
edges: []align(1) const Edge,
surfedges: []align(1) const i32,
models: []align(1) const Model,

const LumpField = struct {
    field: []const u8,
    lump: usize,
};

// const lump_fields = [_]LumpField{
//     .{ .field = "entdata", .lump = LUMP_ENTITIES },
//     .{ .field = "planes", .lump = LUMP_PLANES },
//     .{ .field = "texdata", .lump = LUMP_TEXTURES },
//     .{ .field = "vertexes", .lump = LUMP_VERTEXES },
//     .{ .field = "visdata", .lump = LUMP_VISIBILITY },
//     .{ .field = "nodes", .lump = LUMP_NODES },
//     .{ .field = "texinfo", .lump = LUMP_TEXINFO },
//     .{ .field = "faces", .lump = LUMP_FACES },
//     .{ .field = "lightdata", .lump = LUMP_LIGHTING },
//     .{ .field = "clipnodes", .lump = LUMP_CLIPNODES },
//     .{ .field = "leafs", .lump = LUMP_LEAFS },
//     .{ .field = "marksurfaces", .lump = LUMP_MARKSURFACES },
//     .{ .field = "edges", .lump = LUMP_EDGES },
//     .{ .field = "surfedges", .lump = LUMP_SURFEDGES },
//     .{ .field = "models", .lump = LUMP_MODELS },
// };

// qrad order of write
const lump_fields = [_]LumpField{
    .{ .field = "planes", .lump = LUMP_PLANES },
    .{ .field = "leafs", .lump = LUMP_LEAFS },
    .{ .field = "vertexes", .lump = LUMP_VERTEXES },
    .{ .field = "nodes", .lump = LUMP_NODES },
    .{ .field = "texinfo", .lump = LUMP_TEXINFO },
    .{ .field = "faces", .lump = LUMP_FACES },
    .{ .field = "clipnodes", .lump = LUMP_CLIPNODES },
    .{ .field = "marksurfaces", .lump = LUMP_MARKSURFACES },
    .{ .field = "surfedges", .lump = LUMP_SURFEDGES },
    .{ .field = "edges", .lump = LUMP_EDGES },
    .{ .field = "models", .lump = LUMP_MODELS },

    .{ .field = "lightdata", .lump = LUMP_LIGHTING },
    .{ .field = "visdata", .lump = LUMP_VISIBILITY },
    .{ .field = "entdata", .lump = LUMP_ENTITIES },
    .{ .field = "texdata", .lump = LUMP_TEXTURES },
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, filename: []const u8) !Bsp {
    const cwd = Io.Dir.cwd();

    const bytes = cwd.readFileAlloc(io, filename, allocator, .unlimited) catch |err| {
        const open_err_ints = comptime blk: {
            const set = @typeInfo(std.Io.File.OpenError).error_set.?;
            var ints: [set.len]anyerror = undefined;
            for (set, 0..) |member, i| {
                ints[i] = @field(std.Io.File.OpenError, member.name);
            }
            break :blk ints;
        };

        inline for (open_err_ints) |open_err| {
            if (err == open_err) {
                return qError("Error opening {s}: {s}", .{filename, @errorName(err)}, err);
            }
        }

        return err;
    };


    if (bytes.len < @sizeOf(Header)) {
        allocator.free(bytes);
        return error.FileTooShort;
    }

    const header: *const Header = @ptrCast(@alignCast(bytes.ptr));

    if (header.version != 30) {
        return qError("{s} is version {d}, not {d}", .{ filename, header.version, BSPVERSION }, error.WrongVersion);
    }

    var bsp: Bsp = undefined;
    bsp.bytes = bytes;

    inline for (lump_fields) |info| {
        const Slice = @TypeOf(@field(bsp, info.field));
        const T = std.meta.Child(Slice);

        @field(bsp, info.field) =
            try lumpSlice(T, bytes, header.lumps[info.lump]);
    }

    return bsp;
}

pub fn deinit(self: *const Bsp, allocator: std.mem.Allocator) void {
    allocator.free(self.bytes);
}

fn lumpSlice(comptime T: type, data: []u8, lump: Lump) ![]align(1) T {
    const start: usize = @intCast(lump.fileofs);
    const length: usize = @intCast(lump.filelen);

    if (length % @sizeOf(T) != 0)
        return qError("LoadBSPFile: odd lump size", .{}, error.OddLumpSize);

    const end = start + length;
    return std.mem.bytesAsSlice(T, data[start..end]);
}

fn writeLump(writer: *std.Io.Writer, data: anytype, pos: *usize) !Lump {
    const raw = std.mem.sliceAsBytes(data);
    const start = pos.*;

    try writer.writeAll(raw);

    const n = raw.len;

    const aligned = (n + 3) & ~@as(usize, 3);
    const pad = aligned - n;
    if (pad > 0) {
        const zeros = [3]u8{ 0, 0, 0 };
        try writer.writeAll(zeros[0..pad]);
    }

    pos.* += aligned;

    return .{
        .fileofs = @intCast(start),
        .filelen = @intCast(n),
    };
}

pub fn writeFile(self: *const Bsp, io: std.Io, filename: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, filename, .{});
    defer file.close(io);

    var header: Header = .{
        .version = BSPVERSION,
    };
    const header_bytes = std.mem.asBytes(&header);

    var buf: [65536]u8 = undefined;
    var w = file.writer(io, &buf);
    var writer = &w.interface;

    try writer.writeAll(header_bytes);

    var pos: usize = @sizeOf(Header);

    inline for (lump_fields) |info| {
        const slice = @field(self, info.field);
        header.lumps[info.lump] = try writeLump(writer, slice, &pos);
        // std.debug.print("{s}: {any}\n", .{ info.field, header.lumps[info.lump] });
    }

    try w.seekTo(0);

    try writer.writeAll(header_bytes);
    try writer.flush();
}

pub const Epair = struct {
    key: []const u8,
    value: [:0]const u8,
};

pub const Entity = struct {
    epairs: []Epair,

    pub fn deinit(self: Entity, allocator: std.mem.Allocator) void {
        for (self.epairs) |epair| {
            allocator.free(epair.key);
            allocator.free(epair.value);
        }
        allocator.free(self.epairs);
    }

    // Needs to be 0 sentinel'd so that it works with c functions
    pub fn valueForKey(self: Entity, key: []const u8) ?[:0]const u8 {
        for (self.epairs) |epair| {
            if (std.mem.eql(u8, epair.key, key)) return epair.value;
        }

        return null;
    }

    pub fn floatForKey(self: Entity, key: []const u8) f32 {
        const k = self.valueForKey(key) orelse "";
        return @floatCast(c.atof(k));
    }

    pub fn vectorForKey(self: Entity, key: []const u8) Vec3 {
        const k = self.valueForKey(key) orelse "";
        var v1: f64 = 0;
        var v2: f64 = 0;
        var v3: f64 = 0;
        _ = c.sscanf(k, "%lf %lf %lf", &v1, &v2, &v3);
        return .{ @floatCast(v1), @floatCast(v2), @floatCast(v3) };
    }
};

fn parseEpair(allocator: std.mem.Allocator, script: *ScripLib) !Epair {
    if (script.currentToken().len >= MAX_KEY - 1) return qError("ParseEpar: token too long", .{}, error.TokenTooLong);
    const key = try allocator.dupe(u8, script.currentToken());
    _ = try script.getToken(false);
    if (script.currentToken().len >= MAX_VALUE - 1) return qError("ParseEpar: token too long", .{}, error.TokenTooLong);
    const value = try allocator.dupeSentinel(u8, script.currentToken(), 0);

    return .{
        .key = key,
        .value = value,
    };
}

fn parseEntity(allocator: std.mem.Allocator, script: *ScripLib, entities: *std.ArrayList(Entity)) !bool {
    if (!try script.getToken(true)) return false;
    if (!std.mem.eql(u8, script.currentToken(), "{")) return qError("ParseEntity: {{ not found", .{}, error.ExpectedOpenBrace);

    if (entities.items.len == MAX_MAP_ENTITIES) return qError("num_entities == MAX_MAP_ENTITIES", .{}, error.MaxMapEntities);

    var epairs = std.ArrayList(Epair).empty;

    while (true) {
        if (!try script.getToken(true)) return qError("ParseEntity: EOF without closing brace", .{}, error.UnexpectedEof);
        if (std.mem.eql(u8, script.currentToken(), "}")) break;

        try epairs.append(allocator, try parseEpair(allocator, script));
    }

    try entities.append(allocator, .{ .epairs = try epairs.toOwnedSlice(allocator) });

    return true;
}

pub fn parseEntities(allocator: std.mem.Allocator, bsp: *const Bsp) ![]Entity {
    var script = ScripLib.init(bsp.entdata);
    var entities = std.ArrayList(Entity).empty;

    while (try parseEntity(allocator, &script, &entities)) {}

    return try entities.toOwnedSlice(allocator);
}

pub const Lump = extern struct {
    fileofs: i32 = 0,
    filelen: i32 = 0,
};

pub const Header = extern struct {
    version: i32,
    lumps: [HEADER_LUMPS]Lump = @splat(.{}),
};

pub const Plane = extern struct {
    normal: [3]f32,
    dist: f32,
    type: i32,
};

pub const MiptexLump = extern struct {
    nummiptex: i32,
};

pub const Miptex = extern struct {
    name: [16]u8,
    width: u32,
    height: u32,
    offsets: [4]u32,
};

pub const Vertex = extern struct {
    point: [3]f32,
};

pub const Node = extern struct {
    planenum: i32,
    children: [2]i16,
    mins: [3]i16,
    maxs: [3]i16,
    firstface: u16,
    numfaces: u16,
};

pub const Texinfo = extern struct {
    vecs: [2][4]f32,
    miptex: i32,
    flags: i32,
};

pub const Face = extern struct {
    planenum: u16,
    side: u16,
    firstedge: u32,
    numedges: u16,
    texinfo: u16,
    styles: [MAXLIGHTMAPS]u8,
    lightofs: i32,
};

pub const Leaf = extern struct {
    contents: i32,
    visofs: i32,
    mins: [3]i16,
    maxs: [3]i16,
    firstmarksurface: u16,
    nummarksurfaces: u16,
    ambient_level: [4]u8,
};

pub const Edge = extern struct {
    v: [2]u16,
};

pub const Model = extern struct {
    mins: [3]f32,
    maxs: [3]f32,
    origin: [3]f32,
    headnode: [MAX_MAP_HULLS]i32,
    visleafs: i32,
    firstface: i32,
    numfaces: i32,
};
