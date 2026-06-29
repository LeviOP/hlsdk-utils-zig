pub const Vec3 = @Vector(3, f32);

pub fn dotProduct(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

pub fn vectorNormalize(v: Vec3) Vec3 {
    const len = @sqrt(@reduce(.Add, v * v));
    if (len == 0) return v;
    return v / @as(Vec3, @splat(len));
}

pub fn vectorLength(v: Vec3) f32 {
    return @sqrt(@reduce(.Add, v * v));
}

pub const ON_EPSILON = 0.01;
pub const EQUAL_EPSILON = 0.001;

pub fn vectorCompare(a: Vec3, b: Vec3) bool {
    const diff = @abs(a - b);
    return @reduce(.And, diff <= @as(Vec3, @splat(EQUAL_EPSILON)));
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
