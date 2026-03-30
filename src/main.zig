const std = @import("std");
const builtin = @import("builtin");
const geoip = @import("geoip.zig");
const geosite = @import("geosite.zig");

const max_input_size = 256 * 1024 * 1024;
const app_version = "1.1";

const Command = enum {
    geosite_list,
    geosite_export,
    geoip_list,
    geoip_export,
    version,
};

const Options = struct {
    command: Command,
    input: []const u8,
    categories: ?[]const u8 = null,
    output: ?[]const u8 = null,
    ip_family: geoip.IPFamily = .both,
};

pub fn main() void {
    run() catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        switch (err) {
            error.HelpRequested => {
                printUsage(std.fs.File.stdout().deprecatedWriter()) catch {};
                std.process.exit(0);
            },
            error.InvalidArguments => {
                printUsage(stderr) catch {};
            },
            error.CategoryNotFound => {
                stderr.print("category not found\n", .{}) catch {};
            },
            else => {
                stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
            },
        }
        std.process.exit(1);
    };
}

fn run() !void {
    const allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = try parseArgs(args);
    if (options.command == .version) {
        try std.fs.File.stdout().writeAll(std.mem.trimRight(u8, app_version, "\r\n"));
        try std.fs.File.stdout().writeAll("\n");
        return;
    }

    const data = try std.fs.cwd().readFileAlloc(allocator, options.input, max_input_size);
    defer allocator.free(data);

    switch (options.command) {
        .geosite_list => {
            if (options.output) |path| {
                var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
                defer file.close();
                try runGeoSiteList(allocator, file.deprecatedWriter(), data);
            } else {
                try runGeoSiteList(allocator, std.fs.File.stdout().deprecatedWriter(), data);
            }
        },
        .geosite_export => {
            const categories_raw = options.categories orelse return error.InvalidArguments;
            const categories = try parseCategoryList(allocator, categories_raw);
            defer allocator.free(categories);

            if (options.output) |path| {
                var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
                defer file.close();
                try geosite.exportCategories(allocator, file.deprecatedWriter(), data, categories);
            } else {
                try geosite.exportCategories(allocator, std.fs.File.stdout().deprecatedWriter(), data, categories);
            }
        },
        .geoip_list => {
            if (options.output) |path| {
                var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
                defer file.close();
                try runGeoIPList(allocator, file.deprecatedWriter(), data);
            } else {
                try runGeoIPList(allocator, std.fs.File.stdout().deprecatedWriter(), data);
            }
        },
        .geoip_export => {
            const categories_raw = options.categories orelse return error.InvalidArguments;
            const categories = try parseCategoryList(allocator, categories_raw);
            defer allocator.free(categories);

            if (options.output) |path| {
                var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
                defer file.close();
                try geoip.exportCategories(allocator, file.deprecatedWriter(), data, categories, options.ip_family);
            } else {
                try geoip.exportCategories(allocator, std.fs.File.stdout().deprecatedWriter(), data, categories, options.ip_family);
            }
        },
        .version => unreachable,
    }
}

fn runGeoSiteList(allocator: std.mem.Allocator, writer: anytype, data: []const u8) !void {
    const categories = try geosite.listCategories(allocator, data);
    defer allocator.free(categories);

    for (categories) |category| {
        try writer.writeAll(category);
        try writer.writeByte('\n');
    }
}

fn runGeoIPList(allocator: std.mem.Allocator, writer: anytype, data: []const u8) !void {
    const categories = try geoip.listCategories(allocator, data);
    defer allocator.free(categories);

    for (categories) |category| {
        try writer.writeAll(category);
        try writer.writeByte('\n');
    }
}

fn parseArgs(args: []const []const u8) !Options {
    if (args.len < 2) {
        return error.InvalidArguments;
    }

    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        return error.HelpRequested;
    }
    if (std.mem.eql(u8, args[1], "-v") or std.mem.eql(u8, args[1], "--version")) {
        return .{
            .command = .version,
            .input = "",
        };
    }

    const command = if (std.mem.eql(u8, args[1], "list"))
        Command.geosite_list
    else if (std.mem.eql(u8, args[1], "export"))
        Command.geosite_export
    else if (std.mem.eql(u8, args[1], "geoip-list"))
        Command.geoip_list
    else if (std.mem.eql(u8, args[1], "geoip-export"))
        Command.geoip_export
    else
        return error.InvalidArguments;

    var options = Options{
        .command = command,
        .input = "",
    };

    var want_ipv4 = false;
    var want_ipv6 = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.input = args[i];
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--category")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.categories = args[i];
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.output = args[i];
        } else if (std.mem.eql(u8, arg, "--ipv4")) {
            want_ipv4 = true;
        } else if (std.mem.eql(u8, arg, "--ipv6")) {
            want_ipv6 = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        } else {
            return error.InvalidArguments;
        }
    }

    if (options.input.len == 0) {
        return error.InvalidArguments;
    }

    if ((command == .geosite_export or command == .geoip_export) and options.categories == null) {
        return error.InvalidArguments;
    }

    if (want_ipv4 or want_ipv6) {
        if (command != .geoip_export) return error.InvalidArguments;
        options.ip_family = if (want_ipv4 and want_ipv6)
            .both
        else if (want_ipv4)
            .ipv4
        else
            .ipv6;
    }

    return options;
}

fn parseCategoryList(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    var categories: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer categories.deinit(allocator);

    var start: usize = 0;
    var i: usize = 0;
    while (i <= raw.len) : (i += 1) {
        if (i != raw.len and raw[i] != ',') {
            continue;
        }

        const category = std.mem.trim(u8, raw[start..i], " \t\r\n");
        if (category.len != 0 and !containsCategoryIgnoreCase(categories.items, category)) {
            try categories.append(allocator, category);
        }
        start = i + 1;
    }

    if (categories.items.len == 0) {
        return error.InvalidArguments;
    }

    return categories.toOwnedSlice(allocator);
}

fn containsCategoryIgnoreCase(categories: []const []const u8, wanted: []const u8) bool {
    for (categories) |category| {
        if (std.ascii.eqlIgnoreCase(category, wanted)) {
            return true;
        }
    }
    return false;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage:
        \\  geotool list -i <geosite.dat> [-o <file>]
        \\  geotool export -i <geosite.dat> -c <category[,category...]> [-o <file>]
        \\  geotool geoip-list -i <geoip.dat> [-o <file>]
        \\  geotool geoip-export -i <geoip.dat> -c <category[,category...]> [--ipv4] [--ipv6] [-o <file>]
        \\
        \\Options:
        \\  -i, --input       Path to geosite/dlc dat file
        \\  -c, --category    One or more category names, separated by commas
        \\  -o, --output      Write result to file instead of stdout
        \\      --ipv4        Only export IPv4 CIDR rules for geoip-export
        \\      --ipv6        Only export IPv6 CIDR rules for geoip-export
        \\  -v, --version     Show version
        \\  -h, --help        Show this help
        \\
    );
}
