const std = @import("std");

pub const Error = error{
    InvalidLength,
    InvalidWireType,
    Overflow,
    UnexpectedEof,
};

pub const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    length_delimited = 2,
    start_group = 3,
    end_group = 4,
    fixed32 = 5,
};

pub const Field = struct {
    number: u64,
    wire_type: WireType,
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{
            .data = data,
        };
    }

    pub fn eof(self: Reader) bool {
        return self.pos >= self.data.len;
    }

    pub fn readField(self: *Reader) Error!Field {
        const raw = try self.readVarint();
        const wire = switch (raw & 0x07) {
            0 => WireType.varint,
            1 => WireType.fixed64,
            2 => WireType.length_delimited,
            3 => WireType.start_group,
            4 => WireType.end_group,
            5 => WireType.fixed32,
            else => return error.InvalidWireType,
        };
        return .{
            .number = raw >> 3,
            .wire_type = wire,
        };
    }

    pub fn readVarint(self: *Reader) Error!u64 {
        var value: u64 = 0;
        var shift: u6 = 0;

        while (true) {
            if (self.pos >= self.data.len) {
                return error.UnexpectedEof;
            }

            const byte = self.data[self.pos];
            self.pos += 1;

            value |= (@as(u64, byte & 0x7f) << shift);
            if ((byte & 0x80) == 0) {
                return value;
            }

            if (shift >= 63) {
                return error.Overflow;
            }
            shift += 7;
        }
    }

    pub fn readBytes(self: *Reader) Error![]const u8 {
        const len_u64 = try self.readVarint();
        const len = std.math.cast(usize, len_u64) orelse return error.InvalidLength;
        if (len > self.data.len - self.pos) {
            return error.UnexpectedEof;
        }

        const bytes = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return bytes;
    }

    pub fn skip(self: *Reader, wire_type: WireType) Error!void {
        switch (wire_type) {
            .varint => _ = try self.readVarint(),
            .fixed64 => try self.skipBytes(8),
            .length_delimited => _ = try self.readBytes(),
            .fixed32 => try self.skipBytes(4),
            .start_group, .end_group => return error.InvalidWireType,
        }
    }

    fn skipBytes(self: *Reader, len: usize) Error!void {
        if (len > self.data.len - self.pos) {
            return error.UnexpectedEof;
        }
        self.pos += len;
    }
};
