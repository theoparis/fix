//! `fix daemon` — run a Nix-compatible daemon server to manage store paths and execute builds.

const std = @import("std");
const store = @import("store");
const ProcessContext = @import("../process_context.zig").ProcessContext;

pub const synopsis =
    \\usage: fix daemon [options]
    \\
    \\run a Nix-compatible worker-protocol daemon to manage the store and execute builds.
    \\
    \\options:
    \\  --store <dir>        path to store directory (default: .fix/store)
    \\  --store-dir <dir>    path to store directory (default: .fix/store)
    \\  --socket <path>      path to Unix domain socket to bind (default: <store-dir>/socket)
    \\  --sandbox <mode>     build sandbox mode: none, relaxed, pure, chroot (default: none)
    \\  --chroot <dir>       root directory for chroot builds
    \\  --stdio              serve single connection over stdin/stdout
    \\  -h, --help           print this help message
;

pub fn run(process: ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var store_dir: []const u8 = ".fix/store";
    var socket_path: ?[]const u8 = null;
    var sandbox_mode: store.daemon.SandboxMode = .none;
    var chroot_dir: ?[]const u8 = null;
    var use_stdio = false;

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
        } else if (std.mem.eql(u8, arg, "--stdio")) {
            use_stdio = true;
        } else if (std.mem.eql(u8, arg, "--store") or std.mem.eql(u8, arg, "--store-dir")) {
            store_dir = args_iter.next() orelse {
                stderr.print("error: expected directory path after {s}\n", .{arg}) catch {};
                stderr.flush() catch {};
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--socket")) {
            socket_path = args_iter.next() orelse {
                stderr.print("error: expected socket path after --socket\n", .{}) catch {};
                stderr.flush() catch {};
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--sandbox")) {
            const mode_str = args_iter.next() orelse {
                stderr.print("error: expected mode (none, relaxed, pure, chroot) after --sandbox\n", .{}) catch {};
                stderr.flush() catch {};
                return 2;
            };
            sandbox_mode = store.daemon.SandboxMode.fromString(mode_str) orelse {
                stderr.print("error: invalid sandbox mode '{s}' (expected none, relaxed, pure, chroot)\n", .{mode_str}) catch {};
                stderr.flush() catch {};
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--chroot")) {
            chroot_dir = args_iter.next() orelse {
                stderr.print("error: expected root directory after --chroot\n", .{}) catch {};
                stderr.flush() catch {};
                return 2;
            };
            sandbox_mode = .chroot;
        } else if (std.mem.startsWith(u8, arg, "--sandbox=")) {
            const mode_str = arg["--sandbox=".len..];
            sandbox_mode = store.daemon.SandboxMode.fromString(mode_str) orelse {
                stderr.print("error: invalid sandbox mode '{s}' (expected none, relaxed, pure, chroot)\n", .{mode_str}) catch {};
                stderr.flush() catch {};
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--chroot=")) {
            chroot_dir = arg["--chroot=".len..];
            sandbox_mode = .chroot;
        } else if (std.mem.eql(u8, arg, "--no-sandbox")) {
            sandbox_mode = .none;
        } else if (std.mem.startsWith(u8, arg, "--store=")) {
            store_dir = arg["--store=".len..];
        } else if (std.mem.startsWith(u8, arg, "--store-dir=")) {
            store_dir = arg["--store-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--socket=")) {
            socket_path = arg["--socket=".len..];
        } else {
            stderr.print("error: unrecognized option '{s}'\n\n{s}\n", .{ arg, synopsis }) catch {};
            stderr.flush() catch {};
            return 2;
        }
    }

    var server = try store.daemon.Server.init(allocator, init.io, .{
        .store_dir = store_dir,
        .socket_path = socket_path,
        .sandbox_mode = sandbox_mode,
        .chroot_dir = chroot_dir,
    });
    defer server.deinit();

    if (use_stdio) {
        var in_stream_buf: [64 * 1024]u8 = undefined;
        var out_stream_buf: [64 * 1024]u8 = undefined;
        var stdin = std.Io.File.stdin().readerStreaming(init.io, &in_stream_buf);
        var stdout_stream = std.Io.File.stdout().writerStreaming(init.io, &out_stream_buf);
        server.serveStream(&stdin.interface, &stdout_stream.interface) catch |err| switch (err) {
            error.EndOfStream => return 0,
            else => return 1,
        };
        return 0;
    } else {
        stderr.print("fix-daemon: listening on unix://{s} (store: {s})\n", .{ server.socket_path, server.store_dir }) catch {};
        stderr.flush() catch {};
        server.listenAndServe() catch |err| {
            stderr.print("fix-daemon error: {s}\n", .{@errorName(err)}) catch {};
            stderr.flush() catch {};
            return 1;
        };
        return 0;
    }
}
