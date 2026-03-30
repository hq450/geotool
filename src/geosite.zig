const std = @import("std");
const pb = @import("pb.zig");

pub const Error = error{
    CategoryNotFound,
    MissingCategory,
    MissingDomainValue,
    OutOfMemory,
} || pb.Error;

const AttributeValue = union(enum) {
    none: void,
    bool: bool,
    int: i64,
};

const Attribute = struct {
    key: []const u8 = "",
    value: AttributeValue = .{ .none = {} },
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

pub fn exportCategory(
    allocator: std.mem.Allocator,
    writer: anytype,
    data: []const u8,
    wanted: []const u8,
) !void {
    const wanted_categories = [_][]const u8{wanted};
    try exportCategories(allocator, writer, data, &wanted_categories);
}

pub fn exportCategories(
    allocator: std.mem.Allocator,
    writer: anytype,
    data: []const u8,
    wanted_categories: []const []const u8,
) !void {
    const unique_categories = try dedupeCategories(allocator, wanted_categories);
    defer allocator.free(unique_categories);

    if (unique_categories.len == 0) {
        return error.CategoryNotFound;
    }

    try ensureCategoriesExist(allocator, data, unique_categories);

    var attributes: std.ArrayListUnmanaged(Attribute) = .{};
    defer attributes.deinit(allocator);

    var line = std.array_list.Managed(u8).init(allocator);
    defer line.deinit();

    var seen_rules = std.BufSet.init(allocator);
    defer seen_rules.deinit();

    for (unique_categories) |wanted| {
        try exportSingleCategory(
            writer,
            data,
            wanted,
            allocator,
            &attributes,
            &line,
            &seen_rules,
        );
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
            4 => {
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
    attributes: *std.ArrayListUnmanaged(Attribute),
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
                try writeGeoSite(writer, entry, allocator, attributes, line, seen_rules);
                return;
            }
            continue;
        }
        try reader.skip(field.wire_type);
    }

    return error.CategoryNotFound;
}

fn writeGeoSite(
    writer: anytype,
    entry: []const u8,
    allocator: std.mem.Allocator,
    attributes: *std.ArrayListUnmanaged(Attribute),
    line: *std.array_list.Managed(u8),
    seen_rules: *std.BufSet,
) !void {
    var reader = pb.Reader.init(entry);
    while (!reader.eof()) {
        const field = try reader.readField();
        switch (field.number) {
            1, 4 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                _ = try reader.readBytes();
            },
            2 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                try writeDomainRule(
                    writer,
                    try reader.readBytes(),
                    allocator,
                    attributes,
                    line,
                    seen_rules,
                );
            },
            else => try reader.skip(field.wire_type),
        }
    }
}

fn writeDomainRule(
    writer: anytype,
    message: []const u8,
    allocator: std.mem.Allocator,
    attributes: *std.ArrayListUnmanaged(Attribute),
    line: *std.array_list.Managed(u8),
    seen_rules: *std.BufSet,
) !void {
    var rule_type: u64 = 0;
    var value: []const u8 = "";
    attributes.clearRetainingCapacity();

    var reader = pb.Reader.init(message);
    while (!reader.eof()) {
        const field = try reader.readField();
        switch (field.number) {
            1 => {
                if (field.wire_type != .varint) return error.InvalidWireType;
                rule_type = try reader.readVarint();
            },
            2 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                value = try reader.readBytes();
            },
            3 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                try attributes.append(allocator, try parseAttribute(try reader.readBytes()));
            },
            else => try reader.skip(field.wire_type),
        }
    }

    if (value.len == 0) return error.MissingDomainValue;

    line.clearRetainingCapacity();
    const line_writer = line.writer();

    try line_writer.writeAll(ruleTypePrefix(rule_type));
    try line_writer.writeByte(':');
    try line_writer.writeAll(value);
    for (attributes.items) |attribute| {
        try writeAttribute(line_writer, attribute);
    }

    if (seen_rules.contains(line.items)) {
        return;
    }

    try seen_rules.insert(line.items);
    try writer.writeAll(line.items);
    try writer.writeByte('\n');
}

fn parseAttribute(message: []const u8) Error!Attribute {
    var attribute = Attribute{};
    var reader = pb.Reader.init(message);

    while (!reader.eof()) {
        const field = try reader.readField();
        switch (field.number) {
            1 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                attribute.key = try reader.readBytes();
            },
            2 => {
                if (field.wire_type != .varint) return error.InvalidWireType;
                attribute.value = .{ .bool = (try reader.readVarint()) != 0 };
            },
            3 => {
                if (field.wire_type != .varint) return error.InvalidWireType;
                const raw = try reader.readVarint();
                attribute.value = .{ .int = decodeInt64(raw) };
            },
            else => try reader.skip(field.wire_type),
        }
    }

    return attribute;
}

fn writeAttribute(writer: anytype, attribute: Attribute) !void {
    if (attribute.key.len == 0) return;

    try writer.writeByte(' ');
    try writer.writeByte('@');
    try writer.writeAll(attribute.key);

    switch (attribute.value) {
        .none => {},
        .bool => |value| {
            if (!value) {
                try writer.writeAll("=false");
            }
        },
        .int => |value| {
            try writer.writeByte('=');
            try writer.print("{}", .{value});
        },
    }
}

fn ruleTypePrefix(rule_type: u64) []const u8 {
    return switch (rule_type) {
        0 => "keyword",
        1 => "regexp",
        2 => "domain",
        3 => "full",
        else => "unknown",
    };
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

fn containsCategoryIgnoreCase(categories: []const []const u8, wanted: []const u8) bool {
    for (categories) |category| {
        if (std.ascii.eqlIgnoreCase(category, wanted)) {
            return true;
        }
    }
    return false;
}

fn decodeInt64(raw: u64) i64 {
    return @bitCast(raw);
}

test "listCategories and exportCategory preserve rule types and attributes" {
    const allocator = std.testing.allocator;
    const data = try buildSampleGeoSiteList(allocator);
    defer allocator.free(data);

    const categories = try listCategories(allocator, data);
    defer allocator.free(categories);

    try std.testing.expectEqual(@as(usize, 1), categories.len);
    try std.testing.expectEqualStrings("TEST", categories[0]);

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    try exportCategory(allocator, output.writer(), data, "test");
    try std.testing.expectEqualStrings(
        \\domain:example.com
        \\full:full.example.com @ads
        \\keyword:foo
        \\regexp:^bar$ @level=7
        \\
    , output.items);
}

test "exportCategory returns CategoryNotFound" {
    const allocator = std.testing.allocator;
    const data = try buildSampleGeoSiteList(allocator);
    defer allocator.free(data);

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    try std.testing.expectError(
        error.CategoryNotFound,
        exportCategory(allocator, output.writer(), data, "missing"),
    );
}

test "exportCategories merges categories and removes duplicate rules" {
    const allocator = std.testing.allocator;
    const data = try buildMergedGeoSiteList(allocator);
    defer allocator.free(data);

    const wanted_categories = [_][]const u8{
        "second",
        "FIRST",
        "second",
    };

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    try exportCategories(allocator, output.writer(), data, &wanted_categories);
    try std.testing.expectEqualStrings(
        \\domain:shared.example
        \\keyword:beta
        \\domain:alpha.example
        \\
    , output.items);
}

fn buildSampleGeoSiteList(allocator: std.mem.Allocator) ![]u8 {
    var root = std.array_list.Managed(u8).init(allocator);
    errdefer root.deinit();

    try appendEmbeddedMessageField(&root, 1, buildSampleGeoSite, allocator);

    return root.toOwnedSlice();
}

fn buildMergedGeoSiteList(allocator: std.mem.Allocator) ![]u8 {
    var root = std.array_list.Managed(u8).init(allocator);
    errdefer root.deinit();

    try appendEmbeddedMessageField(&root, 1, buildMergedGeoSiteFirst, allocator);
    try appendEmbeddedMessageField(&root, 1, buildMergedGeoSiteSecond, allocator);

    return root.toOwnedSlice();
}

fn buildSampleGeoSite(allocator: std.mem.Allocator) ![]u8 {
    var geosite = std.array_list.Managed(u8).init(allocator);
    errdefer geosite.deinit();

    try appendLengthDelimitedField(&geosite, 1, "TEST");
    try appendEmbeddedMessageField(&geosite, 2, buildSampleDomainRoot, allocator);
    try appendEmbeddedMessageField(&geosite, 2, buildSampleDomainFull, allocator);
    try appendEmbeddedMessageField(&geosite, 2, buildSampleDomainKeyword, allocator);
    try appendEmbeddedMessageField(&geosite, 2, buildSampleDomainRegexp, allocator);

    return geosite.toOwnedSlice();
}

fn buildMergedGeoSiteFirst(allocator: std.mem.Allocator) ![]u8 {
    var geosite = std.array_list.Managed(u8).init(allocator);
    errdefer geosite.deinit();

    try appendLengthDelimitedField(&geosite, 1, "FIRST");
    try appendEmbeddedMessageField(&geosite, 2, buildMergedDomainShared, allocator);
    try appendEmbeddedMessageField(&geosite, 2, buildMergedDomainAlpha, allocator);

    return geosite.toOwnedSlice();
}

fn buildMergedGeoSiteSecond(allocator: std.mem.Allocator) ![]u8 {
    var geosite = std.array_list.Managed(u8).init(allocator);
    errdefer geosite.deinit();

    try appendLengthDelimitedField(&geosite, 1, "SECOND");
    try appendEmbeddedMessageField(&geosite, 2, buildMergedDomainShared, allocator);
    try appendEmbeddedMessageField(&geosite, 2, buildMergedDomainBeta, allocator);

    return geosite.toOwnedSlice();
}

fn buildSampleDomainRoot(allocator: std.mem.Allocator) ![]u8 {
    var domain = std.array_list.Managed(u8).init(allocator);
    errdefer domain.deinit();

    try appendVarintField(&domain, 1, 2);
    try appendLengthDelimitedField(&domain, 2, "example.com");

    return domain.toOwnedSlice();
}

fn buildSampleDomainFull(allocator: std.mem.Allocator) ![]u8 {
    var domain = std.array_list.Managed(u8).init(allocator);
    errdefer domain.deinit();

    try appendVarintField(&domain, 1, 3);
    try appendLengthDelimitedField(&domain, 2, "full.example.com");
    try appendEmbeddedMessageField(&domain, 3, buildBoolAttributeAds, allocator);

    return domain.toOwnedSlice();
}

fn buildSampleDomainKeyword(allocator: std.mem.Allocator) ![]u8 {
    var domain = std.array_list.Managed(u8).init(allocator);
    errdefer domain.deinit();

    try appendVarintField(&domain, 1, 0);
    try appendLengthDelimitedField(&domain, 2, "foo");

    return domain.toOwnedSlice();
}

fn buildSampleDomainRegexp(allocator: std.mem.Allocator) ![]u8 {
    var domain = std.array_list.Managed(u8).init(allocator);
    errdefer domain.deinit();

    try appendVarintField(&domain, 1, 1);
    try appendLengthDelimitedField(&domain, 2, "^bar$");
    try appendEmbeddedMessageField(&domain, 3, buildIntAttributeLevel, allocator);

    return domain.toOwnedSlice();
}

fn buildMergedDomainShared(allocator: std.mem.Allocator) ![]u8 {
    var domain = std.array_list.Managed(u8).init(allocator);
    errdefer domain.deinit();

    try appendVarintField(&domain, 1, 2);
    try appendLengthDelimitedField(&domain, 2, "shared.example");

    return domain.toOwnedSlice();
}

fn buildMergedDomainAlpha(allocator: std.mem.Allocator) ![]u8 {
    var domain = std.array_list.Managed(u8).init(allocator);
    errdefer domain.deinit();

    try appendVarintField(&domain, 1, 2);
    try appendLengthDelimitedField(&domain, 2, "alpha.example");

    return domain.toOwnedSlice();
}

fn buildMergedDomainBeta(allocator: std.mem.Allocator) ![]u8 {
    var domain = std.array_list.Managed(u8).init(allocator);
    errdefer domain.deinit();

    try appendVarintField(&domain, 1, 0);
    try appendLengthDelimitedField(&domain, 2, "beta");

    return domain.toOwnedSlice();
}

fn buildBoolAttributeAds(allocator: std.mem.Allocator) ![]u8 {
    var attribute = std.array_list.Managed(u8).init(allocator);
    errdefer attribute.deinit();

    try appendLengthDelimitedField(&attribute, 1, "ads");
    try appendVarintField(&attribute, 2, 1);

    return attribute.toOwnedSlice();
}

fn buildIntAttributeLevel(allocator: std.mem.Allocator) ![]u8 {
    var attribute = std.array_list.Managed(u8).init(allocator);
    errdefer attribute.deinit();

    try appendLengthDelimitedField(&attribute, 1, "level");
    try appendVarintField(&attribute, 3, 7);

    return attribute.toOwnedSlice();
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
