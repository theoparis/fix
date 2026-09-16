//! Sandbox hooks for derivation build execution on Darwin and POSIX systems.

const std = @import("std");

pub const SandboxMode = enum {
    none,
    relaxed,
    pure,
    chroot,

    pub fn fromString(str: []const u8) ?SandboxMode {
        if (std.mem.eql(u8, str, "none") or std.mem.eql(u8, str, "off") or std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "0")) {
            return .none;
        } else if (std.mem.eql(u8, str, "relaxed") or std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "1") or std.mem.eql(u8, str, "auto")) {
            return .relaxed;
        } else if (std.mem.eql(u8, str, "pure") or std.mem.eql(u8, str, "strict")) {
            return .pure;
        } else if (std.mem.eql(u8, str, "chroot")) {
            return .chroot;
        }
        return null;
    }

    pub fn toString(self: SandboxMode) []const u8 {
        return switch (self) {
            .none => "none",
            .relaxed => "relaxed",
            .pure => "pure",
            .chroot => "chroot",
        };
    }
};

pub const SandboxOptions = struct {
    mode: SandboxMode = .none,
    store_dir: []const u8,
    build_dir: []const u8,
    output_paths: []const []const u8 = &.{},
    allow_network: bool = false,
    chroot_dir: ?[]const u8 = null,
    extra_read_paths: []const []const u8 = &.{},
    extra_write_paths: []const []const u8 = &.{},
};

pub fn generateSeatbeltProfile(allocator: std.mem.Allocator, options: SandboxOptions) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    switch (options.mode) {
        .none, .chroot => return try allocator.dupe(u8, "(version 1) (allow default)\n"),
        .relaxed => {
            try buf.appendSlice(allocator,
                \\(version 1)
                \\(allow default)
                \\
            );
            if (!options.allow_network) {
                try buf.appendSlice(allocator, "(deny network*)\n");
            }
            // Deny write access to user homes and host system locations
            try buf.appendSlice(allocator,
                \\(deny file-write*
                \\  (subpath "/Users")
                \\  (subpath "/home")
                \\  (subpath "/usr")
                \\  (subpath "/System")
                \\  (subpath "/Library")
                \\  (subpath "/etc"))
                \\(allow file-write*
                \\  (subpath "/dev")
                \\  (subpath "/private/tmp")
                \\  (subpath "/tmp")
                \\
            );
            const build_line = try std.fmt.allocPrint(allocator, "  (subpath \"{s}\")\n", .{options.build_dir});
            defer allocator.free(build_line);
            try buf.appendSlice(allocator, build_line);

            for (options.output_paths) |out| {
                const out_line = try std.fmt.allocPrint(allocator, "  (subpath \"{s}\")\n", .{out});
                defer allocator.free(out_line);
                try buf.appendSlice(allocator, out_line);
            }
            for (options.extra_write_paths) |p| {
                const p_line = try std.fmt.allocPrint(allocator, "  (subpath \"{s}\")\n", .{p});
                defer allocator.free(p_line);
                try buf.appendSlice(allocator, p_line);
            }
            try buf.appendSlice(allocator, ")\n");
        },
        .pure => {
            try buf.appendSlice(allocator,
                \\(version 1)
                \\(deny default)
                \\(allow process-exec*)
                \\(allow process-fork)
                \\(allow sysctl*)
                \\(allow mach*)
                \\(allow pseudo-tty)
                \\(allow system-socket)
                \\(allow system-fsctl)
                \\(allow system-audit)
                \\(allow signal (target self))
                \\(allow file-ioctl)
                \\(allow ipc-posix-shm*)
                \\(allow file-read-metadata)
                \\(allow file-read*
                \\  (subpath "/dev")
                \\  (subpath "/bin")
                \\  (subpath "/usr")
                \\  (subpath "/System")
                \\  (subpath "/Library")
                \\  (subpath "/Applications")
                \\  (subpath "/System/Volumes")
                \\  (subpath "/System/Cryptexes")
                \\  (subpath "/private/var")
                \\  (subpath "/var")
                \\  (subpath "/private/tmp")
                \\  (subpath "/tmp")
                \\  (subpath "/etc")
                \\  (subpath "/private/etc")
                \\
            );
            const store_line = try std.fmt.allocPrint(allocator, "  (subpath \"{s}\")\n", .{options.store_dir});
            defer allocator.free(store_line);
            try buf.appendSlice(allocator, store_line);

            const build_line = try std.fmt.allocPrint(allocator, "  (subpath \"{s}\")\n", .{options.build_dir});
            defer allocator.free(build_line);
            try buf.appendSlice(allocator, build_line);

            for (options.extra_read_paths) |p| {
                const p_line = try std.fmt.allocPrint(allocator, "  (subpath \"{s}\")\n", .{p});
                defer allocator.free(p_line);
                try buf.appendSlice(allocator, p_line);
            }
            try buf.appendSlice(allocator,
                \\)
                \\(allow file-write*
                \\  (subpath "/dev")
                \\  (subpath "/private/tmp")
                \\  (subpath "/tmp")
                \\
            );
            try buf.appendSlice(allocator, build_line);
            for (options.output_paths) |out| {
                const out_line = try std.fmt.allocPrint(allocator, "  (subpath \"{s}\")\n", .{out});
                defer allocator.free(out_line);
                try buf.appendSlice(allocator, out_line);
            }
            for (options.extra_write_paths) |p| {
                const p_line = try std.fmt.allocPrint(allocator, "  (subpath \"{s}\")\n", .{p});
                defer allocator.free(p_line);
                try buf.appendSlice(allocator, p_line);
            }
            try buf.appendSlice(allocator, ")\n");
            if (!options.allow_network) {
                try buf.appendSlice(allocator, "(deny network*)\n");
            }
        },
    }

    return try allocator.dupe(u8, buf.items);
}

pub fn wrapArgv(allocator: std.mem.Allocator, options: SandboxOptions, original_argv: []const []const u8) ![]const []const u8 {
    switch (options.mode) {
        .none => {
            const result = try allocator.alloc([]const u8, original_argv.len);
            @memcpy(result, original_argv);
            return result;
        },
        .relaxed, .pure => {
            const profile = try generateSeatbeltProfile(allocator, options);
            const prefix = &[_][]const u8{ "sandbox-exec", "-p", profile };
            const result = try allocator.alloc([]const u8, prefix.len + original_argv.len);
            @memcpy(result[0..prefix.len], prefix);
            @memcpy(result[prefix.len..], original_argv);
            return result;
        },
        .chroot => {
            const chroot_target = options.chroot_dir orelse options.build_dir;
            const prefix = &[_][]const u8{ "chroot", chroot_target };
            const result = try allocator.alloc([]const u8, prefix.len + original_argv.len);
            @memcpy(result[0..prefix.len], prefix);
            @memcpy(result[prefix.len..], original_argv);
            return result;
        },
    }
}
