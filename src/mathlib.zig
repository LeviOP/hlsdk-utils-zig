// pub const Vec3 = @Vector(3, f32);
pub const Vec3 = [3]f32;

pub fn vectorAdd(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[0] + b[0],
        a[1] + b[1],
        a[2] + b[2],
    };
}

pub fn vectorSubtract(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[0] - b[0],
        a[1] - b[1],
        a[2] - b[2],
    };
}

pub fn vectorScale(a: [3]f32, scale: f32) [3]f32 {
    return .{
        a[0] * scale,
        a[1] * scale,
        a[2] * scale,
    };
}

pub fn vectorMA(a: [3]f32, scale: f32, b: [3]f32) [3]f32 {
    return .{
        a[0] + scale * b[0],
        a[1] + scale * b[1],
        a[2] + scale * b[2],
    };
}

pub fn dotProduct(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn vectorNormalize(v: Vec3) Vec3 {
    const len = vectorLength(v);
    if (len == 0) return v;
    return .{
        v[0] / len,
        v[1] / len,
        v[2] / len,
    };
}

pub fn vectorLength(v: Vec3) f32 {
    var length: f32 = 0;
    for (0..3) |i|
        length += v[i] * v[i];
    return @sqrt(length);
}

pub const ON_EPSILON = 0.01;
pub const EQUAL_EPSILON = 0.001;

pub fn vectorCompare(a: Vec3, b: Vec3) bool {
    for (0..3) |i| {
        if (@abs(a[i] - b[i]) > EQUAL_EPSILON)
            return false;
    }
    return true;
}

pub fn vectorAvg(v: Vec3) f32 {
    return (v[0] + v[1] + v[2]) / 3.0;
}

pub fn crossProduct(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}
