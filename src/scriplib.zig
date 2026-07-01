const qerror = @import("cmdlib.zig").qerror;

const MAXTOKEN = 512;

const ScripLib = @This();

buffer: []const u8,
pos: usize,
line: usize,
token: [MAXTOKEN]u8,
token_len: usize,
token_ready: bool,
end_of_script: bool,

pub fn init(buffer: []const u8) ScripLib {
    return .{
        .buffer = buffer,
        .pos = 0,
        .line = 1,
        .token = undefined,
        .token_len = 0,
        .token_ready = false,
        .end_of_script = false,
    };
}

pub fn currentToken(self: *ScripLib) []const u8 {
    return self.token[0..self.token_len];
}

pub fn ungetToken(self: *ScripLib) void {
    self.token_ready = true;
}

pub fn endOfScript(self: *ScripLib, crossline: bool) !bool {
    if (!crossline) return qerror("Line {d} is incomplete\n", .{self.line}, error.LineIncomplete);
    self.end_of_script = true;
    return false;
}

pub fn getToken(self: *ScripLib, crossline: bool) !bool {
    if (self.token_ready) {
        self.token_ready = false;
        return true;
    }

    if (self.pos >= self.buffer.len)
        return self.endOfScript(crossline);

    // skip whitespace
    skipspace: while (true) {
        while (self.pos < self.buffer.len and self.buffer[self.pos] <= ' ') {
            if (self.buffer[self.pos] == '\n') {
                if (!crossline) return qerror("Line {d} is incomplete\n", .{self.line}, error.LineIncomplete);
                self.line += 1;
            }
            self.pos += 1;
        }

        if (self.pos >= self.buffer.len)
            return self.endOfScript(crossline);

        // skip comments
        const c = self.buffer[self.pos];
        if (c == ';' or c == '#' or
            (c == '/' and self.pos + 1 < self.buffer.len and self.buffer[self.pos + 1] == '/'))
        {
            if (!crossline) return qerror("Line {d} is incomplete\n", .{self.line}, error.LineIncomplete);
            while (self.pos < self.buffer.len and self.buffer[self.pos] != '\n')
                self.pos += 1;
            continue :skipspace;
        }
        break;
    }

    if (self.pos >= self.buffer.len)
        return self.endOfScript(crossline);

    // copy token
    self.token_len = 0;
    if (self.buffer[self.pos] == '"') {
        self.pos += 1;
        while (self.pos < self.buffer.len and self.buffer[self.pos] != '"') {
            if (self.token_len >= MAXTOKEN) return qerror("Token too large on line {d}", .{self.line}, error.TokenTooLarge);
            self.token[self.token_len] = self.buffer[self.pos];
            self.token_len += 1;
            self.pos += 1;
        }
        self.pos += 1;
    } else {
        while (self.pos < self.buffer.len and
            self.buffer[self.pos] > ' ' and
            self.buffer[self.pos] != ';')
        {
            if (self.token_len >= MAXTOKEN) return qerror("Token too large on line {d}", .{self.line}, error.TokenTooLarge);
            self.token[self.token_len] = self.buffer[self.pos];
            self.token_len += 1;
            self.pos += 1;
        }
    }

    return true;
}

pub fn tokenAvailable(self: *ScripLib) bool {
    var i = self.pos;
    if (i >= self.buffer.len) return false;
    while (self.buffer[i] <= ' ') {
        if (self.buffer[i] == '\n') return false;
        i += 1;
        if (i >= self.buffer.len) return false;
    }
    if (self.buffer[i] == ';') return false;
    return true;
}
