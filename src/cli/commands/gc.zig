//! `fix gc` — delete unreachable store paths.
//!
//! Runs a collection directly against a store directory, seeding the root set
//! from the `gcroots` link directory. The `fix daemon` server records indirect
//! roots there (and shares this exact collector), so a self-contained store
//! collects the same way whether invoked standalone or on the daemon's timer.

const std = @import("std");
const store = @import("store");
const ProcessContext = @import("../process_context.zig").ProcessContext;

pub const synopsis =
    \\usage: fix gc [options]
    \\
    \\delete store paths unreachable from the GC root set, reclaiming disk space.
    \\
    \\options:
    \\  --store-dir <dir>   store directory to collect (default: .fix/store)
    \\  --gcroots <dir>     root-link directory (default: <store-dir>/gcroots, or
    \\                      $NIX_STATE_DIR/gcroots when the store is /nix/store)
    \\  --dry-run           list what would be deleted without deleting it
    \\  -h, --help          print this help message
;

pub fn run(process: ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var store_dir: []const u8 = ".fix/store";
    var gcroots_arg: ?[]const u8 = null;
    var dry_run = false;

    var out_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const stdout = &stdout_w.interface;

    var err_buf: [4096]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writerStreaming(init.io, &err_buf);
    const stderr = &stderr_w.interface;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            stdout.print("{s}\n", .{synopsis}) catch {};
            stdout.flush() catch {};
            return 0;
        } else if (std.mem.eql(u8, arg, "--store-dir") or std.mem.eql(u8, arg, "--store")) {
            store_dir = args_iter.next() orelse {
                stderr.print("error: expected directory path after {s}\n", .{arg}) catch {};
                stderr.flush() catch {};
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--store-dir=")) {
            store_dir = arg["--store-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--store=")) {
            store_dir = arg["--store=".len..];
        } else if (std.mem.eql(u8, arg, "--gcroots")) {
            gcroots_arg = args_iter.next() orelse {
                stderr.print("error: expected directory path after --gcroots\n", .{}) catch {};
                stderr.flush() catch {};
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--gcroots=")) {
            gcroots_arg = arg["--gcroots=".len..];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else {
            stderr.print("error: unrecognized option '{s}'\n\n{s}\n", .{ arg, synopsis }) catch {};
            stderr.flush() catch {};
            return 2;
        }
    }

    const cwd = try std.process.currentPathAlloc(init.io, allocator);
    defer allocator.free(cwd);
    const abs_store = if (std.fs.path.isAbsolute(store_dir))
        try allocator.dupe(u8, store_dir)
    else
        try std.fs.path.resolve(allocator, &.{ cwd, store_dir });
    defer allocator.free(abs_store);

    const state_dir = init.environ_map.get("NIX_STATE_DIR") orelse "/nix/var/nix";
    const gcroots_dir = if (gcroots_arg) |g|
        (if (std.fs.path.isAbsolute(g)) try allocator.dupe(u8, g) else try std.fs.path.resolve(allocator, &.{ cwd, g }))
    else
        try store.daemon.gc.defaultGcrootsDir(allocator, abs_store, state_dir);
    defer allocator.free(gcroots_dir);

    var report = store.daemon.gc.collect(allocator, init.io, .{
        .store_dir = abs_store,
        .gcroots_dir = gcroots_dir,
        .dry_run = dry_run,
    }) catch |err| {
        stderr.print("error: garbage collection failed: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        return 1;
    };
    defer report.deinit();

    if (dry_run) {
        for (report.freed.items) |path| stdout.print("{s}\n", .{path}) catch {};
    }
    stderr.print("fix gc: {d} paths {s} ({d} bytes), {d} live, {d} roots\n", .{
        report.freedCount(),
        if (dry_run) "would be freed" else "freed",
        report.freed_bytes,
        report.live_count,
        report.root_count,
    }) catch {};
    stdout.flush() catch {};
    stderr.flush() catch {};
    return 0;
}
