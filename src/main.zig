const std = @import("std");
const builtin = @import("builtin");
const geosite = @import("geosite.zig");

const max_input_size = 256 * 1024 * 1024;
const app_version = "1.0";

const Command = enum {
    list,
    export_cmd,
    version,
};

const Options = struct {
    command: Command,
    input: []const u8,
    categories: ?[]const u8 = null,
    output: ?[]const u8 = null,
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
        .list => {
            if (options.output) |path| {
                var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
                defer file.close();
                try runList(allocator, file.deprecatedWriter(), data);
            } else {
                try runList(allocator, std.fs.File.stdout().deprecatedWriter(), data);
            }
        },
        .export_cmd => {
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
        .version => unreachable,
    }
}

fn runList(allocator: std.mem.Allocator, writer: anytype, data: []const u8) !void {
    const categories = try geosite.listCategories(allocator, data);
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
        Command.list
    else if (std.mem.eql(u8, args[1], "export"))
        Command.export_cmd
    else
        return error.InvalidArguments;

    var options = Options{
        .command = command,
        .input = "",
    };

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
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        } else {
            return error.InvalidArguments;
        }
    }

    if (options.input.len == 0) {
        return error.InvalidArguments;
    }

    if (command == .export_cmd and options.categories == null) {
        return error.InvalidArguments;
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
        \\
        \\Options:
        \\  -i, --input       Path to geosite/dlc dat file
        \\  -c, --category    One or more category names, separated by commas
        \\  -o, --output      Write result to file instead of stdout
        \\  -v, --version     Show version
        \\  -h, --help        Show this help
        \\
    );
}
