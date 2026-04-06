const std = @import("std");
const builtin = @import("builtin");
const geoip = @import("geoip.zig");
const geosite = @import("geosite.zig");

const max_input_size = 256 * 1024 * 1024;
const max_plan_size = 4 * 1024 * 1024;
const app_version = "1.3";

const Command = enum {
    geosite_list,
    geosite_stat,
    geosite_export,
    geoip_list,
    geoip_stat,
    geoip_export,
    batch_export,
    version,
};

const Options = struct {
    command: Command,
    input: []const u8 = "",
    categories: ?[]const u8 = null,
    output: ?[]const u8 = null,
    ip_family: geoip.IPFamily = .both,
    site_format: geosite.ExportFormat = .raw,
    geosite_input: ?[]const u8 = null,
    geoip_input: ?[]const u8 = null,
    plan: ?[]const u8 = null,
};

const BatchTaskKind = enum {
    site,
    ip,
};

const BatchTask = struct {
    kind: BatchTaskKind,
    categories: []const u8,
    output: []const u8,
    site_format: geosite.ExportFormat = .raw,
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

fn readStreamCompatAlloc(allocator: std.mem.Allocator, file: std.fs.File, max_bytes: usize) ![]u8 {
    var list = std.ArrayList(u8){};
    defer list.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        if (list.items.len + n > max_bytes) return error.FileTooBig;
        try list.appendSlice(allocator, buf[0..n]);
    }

    return try list.toOwnedSlice(allocator);
}

fn readFileCompatAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try readStreamCompatAlloc(allocator, file, max_bytes);
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

    switch (options.command) {
        .batch_export => try runBatchExport(allocator, options),
        .geosite_list => {
            const data = try readFileCompatAlloc(allocator, options.input, max_input_size);
            defer allocator.free(data);
            if (options.output) |path| {
                var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
                defer file.close();
                try runGeoSiteList(allocator, file.deprecatedWriter(), data);
            } else {
                try runGeoSiteList(allocator, std.fs.File.stdout().deprecatedWriter(), data);
            }
        },
        .geosite_stat => {
            const data = try readFileCompatAlloc(allocator, options.input, max_input_size);
            defer allocator.free(data);
            if (options.output) |path| {
                var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
                defer file.close();
                try runGeoSiteStat(allocator, file.deprecatedWriter(), data, options.categories);
            } else {
                try runGeoSiteStat(allocator, std.fs.File.stdout().deprecatedWriter(), data, options.categories);
            }
        },
        .geosite_export => {
            const data = try readFileCompatAlloc(allocator, options.input, max_input_size);
            defer allocator.free(data);
            const categories_raw = options.categories orelse return error.InvalidArguments;
            const categories = try parseCategoryList(allocator, categories_raw);
            defer allocator.free(categories);

            if (options.output) |path| {
                var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
                defer file.close();
                try geosite.exportCategories(allocator, file.deprecatedWriter(), data, categories, options.site_format);
            } else {
                try geosite.exportCategories(allocator, std.fs.File.stdout().deprecatedWriter(), data, categories, options.site_format);
            }
        },
        .geoip_list => {
            const data = try readFileCompatAlloc(allocator, options.input, max_input_size);
            defer allocator.free(data);
            if (options.output) |path| {
                var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
                defer file.close();
                try runGeoIPList(allocator, file.deprecatedWriter(), data);
            } else {
                try runGeoIPList(allocator, std.fs.File.stdout().deprecatedWriter(), data);
            }
        },
        .geoip_stat => {
            const data = try readFileCompatAlloc(allocator, options.input, max_input_size);
            defer allocator.free(data);
            if (options.output) |path| {
                var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
                defer file.close();
                try runGeoIPStat(allocator, file.deprecatedWriter(), data, options.categories, options.ip_family);
            } else {
                try runGeoIPStat(allocator, std.fs.File.stdout().deprecatedWriter(), data, options.categories, options.ip_family);
            }
        },
        .geoip_export => {
            const data = try readFileCompatAlloc(allocator, options.input, max_input_size);
            defer allocator.free(data);
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

fn runBatchExport(allocator: std.mem.Allocator, options: Options) !void {
    const plan_path = options.plan orelse return error.InvalidArguments;
    const plan_data = try readFileCompatAlloc(allocator, plan_path, max_plan_size);
    defer allocator.free(plan_data);

    const tasks = try parseBatchPlan(allocator, plan_data);
    defer allocator.free(tasks);

    var need_geosite = false;
    var need_geoip = false;
    for (tasks) |task| {
        switch (task.kind) {
            .site => need_geosite = true,
            .ip => need_geoip = true,
        }
    }

    var geosite_data: ?[]u8 = null;
    defer if (geosite_data) |data| allocator.free(data);
    if (need_geosite) {
        const path = options.geosite_input orelse return error.InvalidArguments;
        geosite_data = try readFileCompatAlloc(allocator, path, max_input_size);
    }

    var geoip_data: ?[]u8 = null;
    defer if (geoip_data) |data| allocator.free(data);
    if (need_geoip) {
        const path = options.geoip_input orelse return error.InvalidArguments;
        geoip_data = try readFileCompatAlloc(allocator, path, max_input_size);
    }

    for (tasks) |task| {
        const categories = try parseCategoryList(allocator, task.categories);
        defer allocator.free(categories);

        var file = try std.fs.cwd().createFile(task.output, .{ .truncate = true });
        defer file.close();

        switch (task.kind) {
            .site => try geosite.exportCategories(
                allocator,
                file.deprecatedWriter(),
                geosite_data orelse return error.InvalidArguments,
                categories,
                task.site_format,
            ),
            .ip => try geoip.exportCategories(
                allocator,
                file.deprecatedWriter(),
                geoip_data orelse return error.InvalidArguments,
                categories,
                task.ip_family,
            ),
        }
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

fn runGeoSiteStat(allocator: std.mem.Allocator, writer: anytype, data: []const u8, categories_raw: ?[]const u8) !void {
    const stats = try geosite.listCategoryStats(allocator, data);
    defer allocator.free(stats);

    if (categories_raw) |raw| {
        const categories = try parseCategoryList(allocator, raw);
        defer allocator.free(categories);
        for (categories) |wanted| {
            const stat = findGeoSiteStat(stats, wanted) orelse return error.CategoryNotFound;
            try writer.print("{s}\t{}\n", .{ stat.category, stat.count });
        }
        return;
    }

    for (stats) |stat| {
        try writer.print("{s}\t{}\n", .{ stat.category, stat.count });
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

fn runGeoIPStat(allocator: std.mem.Allocator, writer: anytype, data: []const u8, categories_raw: ?[]const u8, family: geoip.IPFamily) !void {
    const stats = try geoip.listCategoryStats(allocator, data, family);
    defer allocator.free(stats);

    if (categories_raw) |raw| {
        const categories = try parseCategoryList(allocator, raw);
        defer allocator.free(categories);
        for (categories) |wanted| {
            const stat = findGeoIPStat(stats, wanted) orelse return error.CategoryNotFound;
            try writer.print("{s}\t{}\n", .{ stat.category, stat.count });
        }
        return;
    }

    for (stats) |stat| {
        try writer.print("{s}\t{}\n", .{ stat.category, stat.count });
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
    else if (std.mem.eql(u8, args[1], "stat"))
        Command.geosite_stat
    else if (std.mem.eql(u8, args[1], "export"))
        Command.geosite_export
    else if (std.mem.eql(u8, args[1], "geoip-list"))
        Command.geoip_list
    else if (std.mem.eql(u8, args[1], "geoip-stat"))
        Command.geoip_stat
    else if (std.mem.eql(u8, args[1], "geoip-export"))
        Command.geoip_export
    else if (std.mem.eql(u8, args[1], "batch-export"))
        Command.batch_export
    else
        return error.InvalidArguments;

    var options = Options{ .command = command };

    var want_ipv4 = false;
    var want_ipv6 = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.input = args[i];
        } else if (std.mem.eql(u8, arg, "--geosite")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.geosite_input = args[i];
        } else if (std.mem.eql(u8, arg, "--geoip")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.geoip_input = args[i];
        } else if (std.mem.eql(u8, arg, "--plan")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.plan = args[i];
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--category")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.categories = args[i];
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.output = args[i];
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            if (command != .geosite_export) return error.InvalidArguments;
            options.site_format = try parseSiteFormat(args[i]);
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

    if (command != .batch_export and options.input.len == 0) {
        return error.InvalidArguments;
    }

    if ((command == .geosite_export or command == .geoip_export) and options.categories == null) {
        return error.InvalidArguments;
    }

    if (command == .batch_export and options.plan == null) {
        return error.InvalidArguments;
    }

    if (want_ipv4 or want_ipv6) {
        if (command != .geoip_export and command != .geoip_stat) return error.InvalidArguments;
        options.ip_family = if (want_ipv4 and want_ipv6)
            .both
        else if (want_ipv4)
            .ipv4
        else
            .ipv6;
    }

    return options;
}

fn findGeoSiteStat(stats: []const geosite.CategoryStat, wanted: []const u8) ?geosite.CategoryStat {
    for (stats) |stat| {
        if (std.ascii.eqlIgnoreCase(stat.category, wanted)) return stat;
    }
    return null;
}

fn findGeoIPStat(stats: []const geoip.CategoryStat, wanted: []const u8) ?geoip.CategoryStat {
    for (stats) |stat| {
        if (std.ascii.eqlIgnoreCase(stat.category, wanted)) return stat;
    }
    return null;
}

fn parseSiteFormat(raw: []const u8) !geosite.ExportFormat {
    if (std.ascii.eqlIgnoreCase(raw, "raw")) return .raw;
    if (std.ascii.eqlIgnoreCase(raw, "domain")) return .domain;
    if (std.ascii.eqlIgnoreCase(raw, "full")) return .full;
    if (std.ascii.eqlIgnoreCase(raw, "suffix")) return .suffix;
    if (std.ascii.eqlIgnoreCase(raw, "keyword")) return .keyword;
    if (std.ascii.eqlIgnoreCase(raw, "regexp")) return .regexp;
    return error.InvalidArguments;
}

fn parseBatchPlan(allocator: std.mem.Allocator, plan_data: []u8) ![]BatchTask {
    var tasks = std.array_list.Managed(BatchTask).init(allocator);
    errdefer tasks.deinit();

    var lines = std.mem.splitScalar(u8, plan_data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;

        var fields = std.mem.splitScalar(u8, line, '|');
        const kind_raw = std.mem.trim(u8, fields.next() orelse return error.InvalidArguments, " \t\r\n");
        const format_raw = std.mem.trim(u8, fields.next() orelse return error.InvalidArguments, " \t\r\n");
        const categories_raw = std.mem.trim(u8, fields.next() orelse return error.InvalidArguments, " \t\r\n");
        const output_raw = std.mem.trim(u8, fields.next() orelse return error.InvalidArguments, " \t\r\n");
        if (fields.next() != null) return error.InvalidArguments;
        if (categories_raw.len == 0 or output_raw.len == 0) return error.InvalidArguments;

        if (std.ascii.eqlIgnoreCase(kind_raw, "site")) {
            try tasks.append(.{
                .kind = .site,
                .categories = categories_raw,
                .output = output_raw,
                .site_format = try parseSiteFormat(format_raw),
            });
        } else if (std.ascii.eqlIgnoreCase(kind_raw, "ip")) {
            const family: geoip.IPFamily = if (std.ascii.eqlIgnoreCase(format_raw, "cidr"))
                .both
            else if (std.ascii.eqlIgnoreCase(format_raw, "cidr4"))
                .ipv4
            else if (std.ascii.eqlIgnoreCase(format_raw, "cidr6"))
                .ipv6
            else
                return error.InvalidArguments;
            try tasks.append(.{
                .kind = .ip,
                .categories = categories_raw,
                .output = output_raw,
                .ip_family = family,
            });
        } else {
            return error.InvalidArguments;
        }
    }

    if (tasks.items.len == 0) return error.InvalidArguments;
    return tasks.toOwnedSlice();
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
        \\  geotool stat -i <geosite.dat> [-c <category[,category...]>] [-o <file>]
        \\  geotool export -i <geosite.dat> -c <category[,category...]> [-f <raw|domain|full|suffix|keyword|regexp>] [-o <file>]
        \\  geotool geoip-list -i <geoip.dat> [-o <file>]
        \\  geotool geoip-stat -i <geoip.dat> [-c <category[,category...]>] [--ipv4] [--ipv6] [-o <file>]
        \\  geotool geoip-export -i <geoip.dat> -c <category[,category...]> [--ipv4] [--ipv6] [-o <file>]
        \\  geotool batch-export --geosite <geosite.dat> --geoip <geoip.dat> --plan <file>
        \\
        \\Options:
        \\  -i, --input       Path to geosite/dlc dat file
        \\  -c, --category    One or more category names, separated by commas
        \\  -f, --format      Export format for geosite export
        \\  -o, --output      Write result to file instead of stdout
        \\      --geosite     Path to geosite.dat for batch-export
        \\      --geoip       Path to geoip.dat for batch-export
        \\      --plan        Batch task file: kind|format|categories|output
        \\      --ipv4        Only export IPv4 CIDR rules for geoip-export
        \\      --ipv6        Only export IPv6 CIDR rules for geoip-export
        \\  -v, --version     Show version
        \\  -h, --help        Show this help
        \\
    );
}
