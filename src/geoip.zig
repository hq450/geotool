const std = @import("std");
const pb = @import("pb.zig");

pub const Error = error{
    CategoryNotFound,
    MissingCategory,
    MissingCIDRAddress,
    InvalidIPAddressLength,
    OutOfMemory,
} || pb.Error;

pub const CategoryStat = struct {
    category: []const u8,
    count: usize,
};

pub const IPFamily = enum {
    both,
    ipv4,
    ipv6,
};

pub fn listCategories(allocator: std.mem.Allocator, data: []const u8) Error![][]const u8 {
    var categories: std.ArrayListUnmanaged([]const u8) = .{};
    defer categories.deinit(allocator);

    var reader = pb.Reader.init(data);
    while (!reader.eof()) {
        const field = try reader.readField();
        if (field.number == 1 and field.wire_type == .length_delimited) {
            const entry = try reader.readBytes();
            try categories.append(allocator, try parseCategory(entry));
            continue;
        }
        try reader.skip(field.wire_type);
    }

    std.mem.sort([]const u8, categories.items, {}, lessThanIgnoreCase);
    return categories.toOwnedSlice(allocator);
}

pub fn listCategoryStats(allocator: std.mem.Allocator, data: []const u8, family: IPFamily) Error![]CategoryStat {
    var stats: std.ArrayListUnmanaged(CategoryStat) = .{};
    defer stats.deinit(allocator);

    var reader = pb.Reader.init(data);
    while (!reader.eof()) {
        const field = try reader.readField();
        if (field.number == 1 and field.wire_type == .length_delimited) {
            const entry = try reader.readBytes();
            try stats.append(allocator, .{
                .category = try parseCategory(entry),
                .count = try countCIDRs(entry, family),
            });
            continue;
        }
        try reader.skip(field.wire_type);
    }

    std.mem.sort(CategoryStat, stats.items, {}, lessThanStatIgnoreCase);
    return stats.toOwnedSlice(allocator);
}

pub fn exportCategories(
    allocator: std.mem.Allocator,
    writer: anytype,
    data: []const u8,
    wanted_categories: []const []const u8,
    family: IPFamily,
) !void {
    const unique_categories = try dedupeCategories(allocator, wanted_categories);
    defer allocator.free(unique_categories);

    if (unique_categories.len == 0) {
        return error.CategoryNotFound;
    }

    try ensureCategoriesExist(allocator, data, unique_categories);

    var line = std.array_list.Managed(u8).init(allocator);
    defer line.deinit();

    var seen_rules = std.BufSet.init(allocator);
    defer seen_rules.deinit();

    for (unique_categories) |wanted| {
        try exportSingleCategory(writer, data, wanted, allocator, family, &line, &seen_rules);
    }
}

fn dedupeCategories(
    allocator: std.mem.Allocator,
    wanted_categories: []const []const u8,
) error{OutOfMemory}![][]const u8 {
    var unique_categories: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer unique_categories.deinit(allocator);

    for (wanted_categories) |wanted| {
        if (!containsCategoryIgnoreCase(unique_categories.items, wanted)) {
            try unique_categories.append(allocator, wanted);
        }
    }

    return unique_categories.toOwnedSlice(allocator);
}

fn parseCategory(entry: []const u8) Error![]const u8 {
    var country_code: []const u8 = "";
    var code: []const u8 = "";

    var reader = pb.Reader.init(entry);
    while (!reader.eof()) {
        const field = try reader.readField();
        switch (field.number) {
            1 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                country_code = try reader.readBytes();
            },
            5 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                code = try reader.readBytes();
            },
            else => try reader.skip(field.wire_type),
        }
    }

    if (country_code.len != 0) return country_code;
    if (code.len != 0) return code;
    return error.MissingCategory;
}

fn countCIDRs(entry: []const u8, family: IPFamily) Error!usize {
    var count: usize = 0;
    var reader = pb.Reader.init(entry);
    while (!reader.eof()) {
        const field = try reader.readField();
        switch (field.number) {
            1, 5 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                _ = try reader.readBytes();
            },
            2 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                const cidr = try reader.readBytes();
                if (try cidrMatchesFamily(cidr, family)) count += 1;
            },
            3 => {
                if (field.wire_type != .varint) return error.InvalidWireType;
                _ = try reader.readVarint();
            },
            4 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                _ = try reader.readBytes();
            },
            else => try reader.skip(field.wire_type),
        }
    }
    return count;
}

fn cidrMatchesFamily(message: []const u8, family: IPFamily) Error!bool {
    var ip: []const u8 = "";
    var reader = pb.Reader.init(message);
    while (!reader.eof()) {
        const field = try reader.readField();
        switch (field.number) {
            1 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                ip = try reader.readBytes();
            },
            2 => {
                if (field.wire_type != .varint) return error.InvalidWireType;
                _ = try reader.readVarint();
            },
            else => try reader.skip(field.wire_type),
        }
    }

    if (ip.len == 0) return error.MissingCIDRAddress;
    const is_ipv4 = ip.len == 4;
    const is_ipv6 = ip.len == 16;
    if (!is_ipv4 and !is_ipv6) return error.InvalidIPAddressLength;
    return switch (family) {
        .both => true,
        .ipv4 => is_ipv4,
        .ipv6 => is_ipv6,
    };
}

fn ensureCategoriesExist(
    allocator: std.mem.Allocator,
    data: []const u8,
    wanted_categories: []const []const u8,
) Error!void {
    const found = try allocator.alloc(bool, wanted_categories.len);
    defer allocator.free(found);
    @memset(found, false);

    var remaining = wanted_categories.len;
    var reader = pb.Reader.init(data);
    while (!reader.eof() and remaining != 0) {
        const field = try reader.readField();
        if (field.number == 1 and field.wire_type == .length_delimited) {
            const entry = try reader.readBytes();
            const category = try parseCategory(entry);

            var i: usize = 0;
            while (i < wanted_categories.len) : (i += 1) {
                if (!found[i] and std.ascii.eqlIgnoreCase(category, wanted_categories[i])) {
                    found[i] = true;
                    remaining -= 1;
                    break;
                }
            }
            continue;
        }
        try reader.skip(field.wire_type);
    }

    if (remaining != 0) {
        return error.CategoryNotFound;
    }
}

fn exportSingleCategory(
    writer: anytype,
    data: []const u8,
    wanted: []const u8,
    allocator: std.mem.Allocator,
    family: IPFamily,
    line: *std.array_list.Managed(u8),
    seen_rules: *std.BufSet,
) !void {
    var reader = pb.Reader.init(data);
    while (!reader.eof()) {
        const field = try reader.readField();
        if (field.number == 1 and field.wire_type == .length_delimited) {
            const entry = try reader.readBytes();
            const category = try parseCategory(entry);
            if (std.ascii.eqlIgnoreCase(category, wanted)) {
                try writeGeoIP(writer, entry, allocator, family, line, seen_rules);
                return;
            }
            continue;
        }
        try reader.skip(field.wire_type);
    }

    return error.CategoryNotFound;
}

fn writeGeoIP(
    writer: anytype,
    entry: []const u8,
    allocator: std.mem.Allocator,
    family: IPFamily,
    line: *std.array_list.Managed(u8),
    seen_rules: *std.BufSet,
) !void {
    var cidrs: std.ArrayListUnmanaged([]const u8) = .{};
    defer cidrs.deinit(allocator);

    var inverse_match = false;

    var reader = pb.Reader.init(entry);
    while (!reader.eof()) {
        const field = try reader.readField();
        switch (field.number) {
            1, 5 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                _ = try reader.readBytes();
            },
            2 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                try cidrs.append(allocator, try reader.readBytes());
            },
            3 => {
                if (field.wire_type != .varint) return error.InvalidWireType;
                inverse_match = (try reader.readVarint()) != 0;
            },
            4 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                _ = try reader.readBytes();
            },
            else => try reader.skip(field.wire_type),
        }
    }

    for (cidrs.items) |cidr| {
        try writeCIDRRule(writer, cidr, inverse_match, family, line, seen_rules);
    }
}

fn writeCIDRRule(
    writer: anytype,
    message: []const u8,
    inverse_match: bool,
    family: IPFamily,
    line: *std.array_list.Managed(u8),
    seen_rules: *std.BufSet,
) !void {
    var ip: []const u8 = "";
    var prefix: u64 = 0;

    var reader = pb.Reader.init(message);
    while (!reader.eof()) {
        const field = try reader.readField();
        switch (field.number) {
            1 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                ip = try reader.readBytes();
            },
            2 => {
                if (field.wire_type != .varint) return error.InvalidWireType;
                prefix = try reader.readVarint();
            },
            else => try reader.skip(field.wire_type),
        }
    }

    if (ip.len == 0) return error.MissingCIDRAddress;

    const is_ipv4 = ip.len == 4;
    const is_ipv6 = ip.len == 16;
    if (!is_ipv4 and !is_ipv6) return error.InvalidIPAddressLength;

    if ((family == .ipv4 and !is_ipv4) or (family == .ipv6 and !is_ipv6)) {
        return;
    }

    line.clearRetainingCapacity();
    const line_writer = line.writer();

    if (inverse_match) {
        try line_writer.writeByte('!');
    }

    if (is_ipv4) {
        try writeIPv4(line_writer, ip);
    } else {
        try writeIPv6(line_writer, ip);
    }

    try line_writer.writeByte('/');
    try line_writer.print("{}", .{prefix});

    if (seen_rules.contains(line.items)) {
        return;
    }

    try seen_rules.insert(line.items);
    try writer.writeAll(line.items);
    try writer.writeByte('\n');
}

fn writeIPv4(writer: anytype, ip: []const u8) !void {
    try writer.print("{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
}

fn writeIPv6(writer: anytype, ip: []const u8) !void {
    if (std.mem.eql(u8, ip[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
        try writer.writeAll("::ffff:");
        try writeIPv4(writer, ip[12..16]);
        return;
    }

    var parts: [8]u16 = undefined;
    var i: usize = 0;
    while (i < parts.len) : (i += 1) {
        parts[i] = (@as(u16, ip[i * 2]) << 8) | @as(u16, ip[i * 2 + 1]);
    }

    var longest_start: usize = parts.len;
    var longest_len: usize = 0;
    var current_start: usize = 0;
    var current_len: usize = 0;

    for (parts, 0..) |part, index| {
        if (part == 0) {
            if (current_len == 0) current_start = index;
            current_len += 1;
            if (current_len > longest_len) {
                longest_start = current_start;
                longest_len = current_len;
            }
        } else {
            current_len = 0;
        }
    }

    if (longest_len < 2) {
        longest_start = parts.len;
        longest_len = 0;
    }

    i = 0;
    var wrote_any = false;
    while (i < parts.len) {
        if (i == longest_start) {
            try writer.writeAll(if (wrote_any) "::" else "::");
            wrote_any = true;
            i += longest_len;
            if (i >= parts.len) break;
            continue;
        }

        if (wrote_any) {
            try writer.writeByte(':');
        }
        try writer.print("{x}", .{parts[i]});
        wrote_any = true;
        i += 1;
    }
}

fn lessThanIgnoreCase(_: void, a: []const u8, b: []const u8) bool {
    const min_len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < min_len) : (i += 1) {
        const lhs = std.ascii.toUpper(a[i]);
        const rhs = std.ascii.toUpper(b[i]);
        if (lhs != rhs) return lhs < rhs;
    }
    return a.len < b.len;
}

fn lessThanStatIgnoreCase(_: void, a: CategoryStat, b: CategoryStat) bool {
    return lessThanIgnoreCase({}, a.category, b.category);
}

fn containsCategoryIgnoreCase(categories: []const []const u8, wanted: []const u8) bool {
    for (categories) |category| {
        if (std.ascii.eqlIgnoreCase(category, wanted)) {
            return true;
        }
    }
    return false;
}

test "listCategories and exportCategories output cidr rules" {
    const allocator = std.testing.allocator;
    const data = try buildSampleGeoIPList(allocator);
    defer allocator.free(data);

    const categories = try listCategories(allocator, data);
    defer allocator.free(categories);

    try std.testing.expectEqual(@as(usize, 2), categories.len);
    try std.testing.expectEqualStrings("INVERSE", categories[0]);
    try std.testing.expectEqualStrings("TEST", categories[1]);

    const wanted_categories = [_][]const u8{ "test", "inverse" };

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    try exportCategories(allocator, output.writer(), data, &wanted_categories, .both);
    try std.testing.expectEqualStrings(
        \\192.0.2.0/24
        \\2001:db8::/32
        \\!198.51.100.0/24
        \\
    , output.items);
}

test "exportCategories merges categories and filters families" {
    const allocator = std.testing.allocator;
    const data = try buildMergedGeoIPList(allocator);
    defer allocator.free(data);

    const wanted_categories = [_][]const u8{
        "second",
        "FIRST",
        "second",
    };

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    try exportCategories(allocator, output.writer(), data, &wanted_categories, .ipv4);
    try std.testing.expectEqualStrings(
        \\203.0.113.0/24
        \\198.51.100.0/24
        \\
    , output.items);
}

test "exportCategories returns CategoryNotFound" {
    const allocator = std.testing.allocator;
    const data = try buildSampleGeoIPList(allocator);
    defer allocator.free(data);

    const wanted_categories = [_][]const u8{"missing"};

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    try std.testing.expectError(
        error.CategoryNotFound,
        exportCategories(allocator, output.writer(), data, &wanted_categories, .both),
    );
}

test "listCategoryStats returns cidr counts" {
    const allocator = std.testing.allocator;
    const data = try buildSampleGeoIPList(allocator);
    defer allocator.free(data);

    const stats = try listCategoryStats(allocator, data, .both);
    defer allocator.free(stats);

    try std.testing.expectEqual(@as(usize, 2), stats.len);
    try std.testing.expectEqualStrings("INVERSE", stats[0].category);
    try std.testing.expectEqual(@as(usize, 1), stats[0].count);
    try std.testing.expectEqualStrings("TEST", stats[1].category);
    try std.testing.expectEqual(@as(usize, 2), stats[1].count);
}

fn buildSampleGeoIPList(allocator: std.mem.Allocator) ![]u8 {
    var root = std.array_list.Managed(u8).init(allocator);
    errdefer root.deinit();

    try appendEmbeddedMessageField(&root, 1, buildSampleGeoIPMain, allocator);
    try appendEmbeddedMessageField(&root, 1, buildSampleGeoIPInverse, allocator);

    return root.toOwnedSlice();
}

fn buildMergedGeoIPList(allocator: std.mem.Allocator) ![]u8 {
    var root = std.array_list.Managed(u8).init(allocator);
    errdefer root.deinit();

    try appendEmbeddedMessageField(&root, 1, buildMergedGeoIPFirst, allocator);
    try appendEmbeddedMessageField(&root, 1, buildMergedGeoIPSecond, allocator);

    return root.toOwnedSlice();
}

fn buildSampleGeoIPMain(allocator: std.mem.Allocator) ![]u8 {
    var geoip = std.array_list.Managed(u8).init(allocator);
    errdefer geoip.deinit();

    try appendLengthDelimitedField(&geoip, 1, "TEST");
    try appendEmbeddedMessageField(&geoip, 2, buildCIDR192, allocator);
    try appendEmbeddedMessageField(&geoip, 2, buildCIDR2001, allocator);

    return geoip.toOwnedSlice();
}

fn buildSampleGeoIPInverse(allocator: std.mem.Allocator) ![]u8 {
    var geoip = std.array_list.Managed(u8).init(allocator);
    errdefer geoip.deinit();

    try appendLengthDelimitedField(&geoip, 1, "INVERSE");
    try appendVarintField(&geoip, 3, 1);
    try appendEmbeddedMessageField(&geoip, 2, buildCIDR198, allocator);

    return geoip.toOwnedSlice();
}

fn buildMergedGeoIPFirst(allocator: std.mem.Allocator) ![]u8 {
    var geoip = std.array_list.Managed(u8).init(allocator);
    errdefer geoip.deinit();

    try appendLengthDelimitedField(&geoip, 1, "FIRST");
    try appendEmbeddedMessageField(&geoip, 2, buildCIDR203, allocator);
    try appendEmbeddedMessageField(&geoip, 2, buildCIDR2001, allocator);

    return geoip.toOwnedSlice();
}

fn buildMergedGeoIPSecond(allocator: std.mem.Allocator) ![]u8 {
    var geoip = std.array_list.Managed(u8).init(allocator);
    errdefer geoip.deinit();

    try appendLengthDelimitedField(&geoip, 1, "SECOND");
    try appendEmbeddedMessageField(&geoip, 2, buildCIDR203, allocator);
    try appendEmbeddedMessageField(&geoip, 2, buildCIDR198, allocator);

    return geoip.toOwnedSlice();
}

fn buildCIDR192(allocator: std.mem.Allocator) ![]u8 {
    var cidr = std.array_list.Managed(u8).init(allocator);
    errdefer cidr.deinit();

    try appendLengthDelimitedField(&cidr, 1, &[_]u8{ 192, 0, 2, 0 });
    try appendVarintField(&cidr, 2, 24);
    return cidr.toOwnedSlice();
}

fn buildCIDR198(allocator: std.mem.Allocator) ![]u8 {
    var cidr = std.array_list.Managed(u8).init(allocator);
    errdefer cidr.deinit();

    try appendLengthDelimitedField(&cidr, 1, &[_]u8{ 198, 51, 100, 0 });
    try appendVarintField(&cidr, 2, 24);
    return cidr.toOwnedSlice();
}

fn buildCIDR203(allocator: std.mem.Allocator) ![]u8 {
    var cidr = std.array_list.Managed(u8).init(allocator);
    errdefer cidr.deinit();

    try appendLengthDelimitedField(&cidr, 1, &[_]u8{ 203, 0, 113, 0 });
    try appendVarintField(&cidr, 2, 24);
    return cidr.toOwnedSlice();
}

fn buildCIDR2001(allocator: std.mem.Allocator) ![]u8 {
    var cidr = std.array_list.Managed(u8).init(allocator);
    errdefer cidr.deinit();

    try appendLengthDelimitedField(&cidr, 1, &[_]u8{
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
        0,    0,    0,    0,    0, 0, 0, 0,
    });
    try appendVarintField(&cidr, 2, 32);
    return cidr.toOwnedSlice();
}

fn appendEmbeddedMessageField(
    bytes: *std.array_list.Managed(u8),
    field_number: u64,
    comptime buildFn: fn (std.mem.Allocator) anyerror![]u8,
    allocator: std.mem.Allocator,
) !void {
    const message = try buildFn(allocator);
    defer allocator.free(message);

    try appendTag(bytes, field_number, .length_delimited);
    try appendVarint(bytes, message.len);
    try bytes.appendSlice(message);
}

fn appendLengthDelimitedField(bytes: *std.array_list.Managed(u8), field_number: u64, value: []const u8) !void {
    try appendTag(bytes, field_number, .length_delimited);
    try appendVarint(bytes, value.len);
    try bytes.appendSlice(value);
}

fn appendVarintField(bytes: *std.array_list.Managed(u8), field_number: u64, value: u64) !void {
    try appendTag(bytes, field_number, .varint);
    try appendVarint(bytes, value);
}

fn appendTag(bytes: *std.array_list.Managed(u8), field_number: u64, wire_type: pb.WireType) !void {
    try appendVarint(bytes, (field_number << 3) | @intFromEnum(wire_type));
}

fn appendVarint(bytes: *std.array_list.Managed(u8), value: u64) !void {
    var current = value;
    while (true) {
        var byte: u8 = @intCast(current & 0x7f);
        current >>= 7;
        if (current != 0) {
            byte |= 0x80;
        }
        try bytes.append(byte);
        if (current == 0) {
            return;
        }
    }
}
