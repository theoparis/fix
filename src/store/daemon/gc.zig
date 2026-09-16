//! Store garbage collection.
//!
//! Reclaims top-level store entries that are unreachable from the GC root set.
//! This is the *store* collector (Nix's `nix-store --gc`), distinct from the
//! evaluator's precise heap collector in `runtime/gc.zig`.
//!
//! Reachability is `store path -> referenced store paths`, computed the same
//! way Nix does:
//!
//! * A `.drv` is not special-cased: scanning its ATerm text finds its input
//!   derivations, input sources, and output paths, so a live derivation keeps
//!   its whole closure. Keeping outputs of a live derivation is deliberately
//!   conservative.
//! * Any other path contributes the store paths named in its regular-file
//!   contents (directories are walked; symlinks are not followed).
//!
//! Roots are explicit (the daemon's temp/indirect roots and the caller's
//! `--root`) plus every symlink found under the `gcroots` directory. A root
//! whose target is already gone is ignored, so a stale link never aborts a
//! collection.

const std = @import("std");

/// Nix's base32 alphabet. Store-path hashes use only these 32 characters.
const base32_alphabet = "0123456789abcdfghijklmnpqrsvwxyz";
const hash_len = 32;

/// Bytes allowed in the name component after `<hash>-` (Nix `checkName`).
fn isNameByte(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return switch (c) {
        '+', '-', '.', '_', '?', '=' => true,
        else => false,
    };
}

fn isValidHashByte(c: u8) bool {
    return std.mem.indexOfScalar(u8, base32_alphabet, c) != null;
}

/// True iff `name` is a top-level store entry: a 32-character base32 hash, a
/// `-`, then a non-empty name. Entries failing this (the `socket`, `gcroots`,
/// lock files, stray junk) are never considered for deletion.
pub fn isStoreEntryName(name: []const u8) bool {
    if (name.len <= hash_len + 1) return false;
    if (name[hash_len] != '-') return false;
    for (name[0..hash_len]) |c| if (!isValidHashByte(c)) return false;
    return true;
}

/// Default gcroots directory. A real `/nix/store` keeps roots in the state
/// directory; a self-contained fix store keeps them beside the store.
pub fn defaultGcrootsDir(allocator: std.mem.Allocator, store_dir: []const u8, state_dir: []const u8) ![]u8 {
    if (std.mem.eql(u8, store_dir, "/nix/store")) {
        return std.fs.path.join(allocator, &.{ state_dir, "gcroots" });
    }
    return std.fs.path.join(allocator, &.{ store_dir, "gcroots" });
}

/// The number of bytes a file contributes to the reclaim report. Directories
/// are summed recursively; symlinks and special files count as zero.
fn pathSize(io: std.Io, allocator: std.mem.Allocator, abs_path: []const u8) u64 {
    const stat = std.Io.Dir.cwd().statFile(io, abs_path, .{ .follow_symlinks = false }) catch return 0;
    switch (stat.kind) {
        .file => return stat.size,
        .directory => {
            var total: u64 = 0;
            var dir = std.Io.Dir.openDirAbsolute(io, abs_path, .{ .iterate = true }) catch return 0;
            defer dir.close(io);
            var iter = dir.iterate();
            while (iter.next(io) catch null) |entry| {
                const child = std.fs.path.join(allocator, &.{ abs_path, entry.name }) catch continue;
                defer allocator.free(child);
                total +%= pathSize(io, allocator, child);
            }
            return total;
        },
        else => return 0,
    }
}

pub const Report = struct {
    allocator: std.mem.Allocator,
    /// Store entries reachable from a root (the closure size).
    live_count: usize = 0,
    /// Roots that resolved to an existing store entry.
    root_count: usize = 0,
    /// Absolute paths deleted (or that `--dry-run` would delete).
    freed: std.ArrayListUnmanaged([]u8) = .empty,
    freed_bytes: u64 = 0,

    pub fn deinit(self: *Report) void {
        for (self.freed.items) |path| self.allocator.free(path);
        self.freed.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn freedCount(self: *const Report) usize {
        return self.freed.items.len;
    }
};

pub const Gc = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []u8,
    gcroots_dir: []u8,
    /// Absolute store paths pinned by the caller (daemon temp roots, `--root`).
    explicit_roots: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        store_dir: []const u8,
        gcroots_dir: []const u8,
    ) !Gc {
        const owned_store = try allocator.dupe(u8, store_dir);
        errdefer allocator.free(owned_store);
        const owned_roots = try allocator.dupe(u8, gcroots_dir);
        return .{
            .allocator = allocator,
            .io = io,
            .store_dir = owned_store,
            .gcroots_dir = owned_roots,
        };
    }

    pub fn deinit(self: *Gc) void {
        for (self.explicit_roots.items) |root| self.allocator.free(root);
        self.explicit_roots.deinit(self.allocator);
        self.allocator.free(self.store_dir);
        self.allocator.free(self.gcroots_dir);
        self.* = undefined;
    }

    /// Pin a store path or root symlink target. Accepts an absolute path (under
    /// this store or `/nix/store`) or a bare `<hash>-<name>` entry name.
    pub fn addRoot(self: *Gc, raw: []const u8) !void {
        const owned = try self.allocator.dupe(u8, raw);
        errdefer self.allocator.free(owned);
        try self.explicit_roots.append(self.allocator, owned);
    }

    /// Record every symlink under `gcroots_dir` as a root. Returns the number
    /// of links considered (whether or not their target still exists).
    pub fn addIndirectRoots(self: *Gc) !usize {
        return self.walkRoots(self.gcroots_dir, 0);
    }

    fn walkRoots(self: *Gc, dir_path: []const u8, depth: usize) !usize {
        if (depth > 32) return 0; // cycle guard against root-dir symlink loops
        var dir = std.Io.Dir.openDirAbsolute(self.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return 0,
            else => return err,
        };
        defer dir.close(self.io);

        var seen: usize = 0;
        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            const child = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(child);
            switch (entry.kind) {
                .directory => seen += try self.walkRoots(child, depth + 1),
                .sym_link => {
                    seen += 1;
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    const n = std.Io.Dir.readLinkAbsolute(self.io, child, &buf) catch continue;
                    const target = buf[0..n];
                    const joined = if (std.fs.path.isAbsolute(target))
                        try self.allocator.dupe(u8, target)
                    else blk: {
                        const parent = std.fs.path.dirname(child) orelse ".";
                        break :blk try std.fs.path.join(self.allocator, &.{ parent, target });
                    };
                    defer self.allocator.free(joined);
                    // Follow the link chain (e.g. `auto/<hash> -> ~/result ->
                    // /store/...`) to the store path it ultimately names.
                    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const canonical = if (std.Io.Dir.realPathFileAbsolute(self.io, joined, &real_buf)) |rn|
                        real_buf[0..rn]
                    else |_|
                        joined;
                    try self.addRoot(canonical);
                },
                else => {},
            }
        }
        return seen;
    }

    /// Collect unreachable entries. When `dry_run` is set, nothing is deleted
    /// and `Report.freed` describes what *would* be removed.
    pub fn run(self: *Gc, dry_run: bool) !Report {
        var entries: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (entries.items) |name| self.allocator.free(name);
            entries.deinit(self.allocator);
        }
        var entry_index: std.StringHashMapUnmanaged([]u8) = .empty;
        defer entry_index.deinit(self.allocator);

        {
            var dir = try std.Io.Dir.openDirAbsolute(self.io, self.store_dir, .{ .iterate = true });
            defer dir.close(self.io);
            var iter = dir.iterate();
            while (iter.next(self.io) catch null) |entry| {
                if (!isStoreEntryName(entry.name)) continue;
                const name = try self.allocator.dupe(u8, entry.name);
                errdefer self.allocator.free(name);
                try entries.append(self.allocator, name);
                try entry_index.put(self.allocator, name, name);
            }
        }

        // Seed the worklist with roots that resolve to a live entry.
        var queue: std.ArrayListUnmanaged([]const u8) = .empty;
        defer queue.deinit(self.allocator);
        var roots_seen: usize = 0;
        for (self.explicit_roots.items) |raw| {
            const name = self.rootEntryName(raw) orelse continue;
            const canonical = entry_index.get(name) orelse continue;
            roots_seen += 1;
            try queue.append(self.allocator, canonical);
        }

        // Young-gated mark over the reference graph; bounded work because each
        // entry is visited at most once.
        var live: std.StringHashMapUnmanaged(void) = .empty;
        defer live.deinit(self.allocator);
        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const name = queue.items[cursor];
            if (live.contains(name)) continue;
            try live.put(self.allocator, name, {});

            var refs: std.ArrayListUnmanaged([]u8) = .empty;
            defer {
                for (refs.items) |r| self.allocator.free(r);
                refs.deinit(self.allocator);
            }
            try self.collectReferences(name, &refs);
            for (refs.items) |ref| {
                if (live.contains(ref)) continue;
                if (entry_index.get(ref)) |canonical| {
                    try queue.append(self.allocator, canonical);
                }
            }
        }

        var report: Report = .{ .allocator = self.allocator };
        errdefer report.deinit();
        report.live_count = live.count();
        report.root_count = roots_seen;

        for (entries.items) |name| {
            if (live.contains(name)) continue;
            const abs_path = try std.fs.path.join(self.allocator, &.{ self.store_dir, name });
            errdefer self.allocator.free(abs_path);
            report.freed_bytes +%= pathSize(self.io, self.allocator, abs_path);
            if (!dry_run) {
                const stat = std.Io.Dir.cwd().statFile(self.io, abs_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => null,
                    else => return err,
                };
                if (stat) |s| switch (s.kind) {
                    .directory => try std.Io.Dir.cwd().deleteTree(self.io, abs_path),
                    else => try std.Io.Dir.deleteFileAbsolute(self.io, abs_path),
                };
            }
            try report.freed.append(self.allocator, abs_path);
        }
        return report;
    }

    /// Map a root (absolute path or bare `hash-name`) to a store entry name.
    fn rootEntryName(self: *Gc, raw: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, raw, self.store_dir) and raw.len > self.store_dir.len and raw[self.store_dir.len] == '/') {
            const name = raw[self.store_dir.len + 1 ..];
            if (std.mem.indexOfScalar(u8, name, '/') != null) return null;
            return name;
        }
        if (!std.mem.eql(u8, self.store_dir, "/nix/store") and
            std.mem.startsWith(u8, raw, "/nix/store/"))
        {
            const name = raw["/nix/store/".len..];
            if (std.mem.indexOfScalar(u8, name, '/') != null) return null;
            return name;
        }
        if (isStoreEntryName(raw)) return raw;
        // A root reached through a canonicalized path (e.g. `/tmp` resolving to
        // `/private/tmp` on macOS) still names a store entry by its basename.
        // Accepting it is conservative: it can only retain, never delete.
        const base = std.fs.path.basename(raw);
        if (isStoreEntryName(base)) return base;
        return null;
    }

    /// Append the store-path names referenced by `name`'s contents.
    fn collectReferences(self: *Gc, name: []const u8, out: *std.ArrayListUnmanaged([]u8)) !void {
        const abs_path = try std.fs.path.join(self.allocator, &.{ self.store_dir, name });
        defer self.allocator.free(abs_path);
        try self.walkReferences(abs_path, out, 0);
    }

    fn walkReferences(self: *Gc, abs_path: []const u8, out: *std.ArrayListUnmanaged([]u8), depth: usize) !void {
        if (depth > 128) return;
        const stat = std.Io.Dir.cwd().statFile(self.io, abs_path, .{ .follow_symlinks = false }) catch return;
        switch (stat.kind) {
            .file => {
                const data = std.Io.Dir.cwd().readFileAlloc(self.io, abs_path, self.allocator, .limited(64 * 1024 * 1024)) catch return;
                defer self.allocator.free(data);
                try self.scanText(data, out);
            },
            .directory => {
                var dir = std.Io.Dir.openDirAbsolute(self.io, abs_path, .{ .iterate = true }) catch return;
                defer dir.close(self.io);
                var iter = dir.iterate();
                while (iter.next(self.io) catch null) |entry| {
                    const child = std.fs.path.join(self.allocator, &.{ abs_path, entry.name }) catch continue;
                    defer self.allocator.free(child);
                    try self.walkReferences(child, out, depth + 1);
                }
            },
            else => {},
        }
    }

    /// Scan `text` for `<prefix>/<32-hash>-<name>` occurrences and append each
    /// distinct basename to `out`. Both this store's prefix and `/nix/store`
    /// are accepted, since derivations are written for a canonical store and
    /// then relocated into a self-contained one.
    fn scanText(self: *Gc, text: []const u8, out: *std.ArrayListUnmanaged([]u8)) !void {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.allocator);
        try self.scanPrefix(text, self.store_dir, out, &seen);
        if (!std.mem.eql(u8, self.store_dir, "/nix/store"))
            try self.scanPrefix(text, "/nix/store", out, &seen);
    }

    fn scanPrefix(
        self: *Gc,
        text: []const u8,
        prefix: []const u8,
        out: *std.ArrayListUnmanaged([]u8),
        seen: *std.StringHashMapUnmanaged(void),
    ) !void {
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, text, search_from, prefix)) |pos| {
            const after = pos + prefix.len;
            search_from = after;
            if (after >= text.len or text[after] != '/') continue;
            const hash_start = after + 1;
            if (hash_start + hash_len >= text.len) continue;
            var valid = true;
            for (text[hash_start .. hash_start + hash_len]) |c| {
                if (!isValidHashByte(c)) {
                    valid = false;
                    break;
                }
            }
            if (!valid or text[hash_start + hash_len] != '-') continue;
            var end = hash_start + hash_len + 1;
            while (end < text.len and isNameByte(text[end])) end += 1;
            if (end == hash_start + hash_len + 1) continue; // no name bytes
            const basename = text[hash_start..end];
            if (seen.contains(basename)) continue;
            try seen.put(self.allocator, basename, {});
            try out.append(self.allocator, try self.allocator.dupe(u8, basename));
        }
    }
};

pub const Options = struct {
    store_dir: []const u8,
    gcroots_dir: []const u8,
    dry_run: bool = false,
};

/// One-shot collection with indirect roots preloaded.
pub fn collect(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
) !Report {
    var gc = try Gc.init(allocator, io, options.store_dir, options.gcroots_dir);
    defer gc.deinit();
    _ = try gc.addIndirectRoots();
    return gc.run(options.dry_run);
}

// --- Tests --------------------------------------------------------------

const testing = std.testing;

fn writeFileAt(io: std.Io, allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    _ = allocator;
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn absStorePath(allocator: std.mem.Allocator, store: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ store, name });
}

test "isStoreEntryName accepts hash-name and rejects junk" {
    try testing.expect(isStoreEntryName("00000000000000000000000000000000-hello-1.0"));
    try testing.expect(!isStoreEntryName("gcroots"));
    try testing.expect(!isStoreEntryName("socket"));
    try testing.expect(!isStoreEntryName("0000000000000000000000000000000-hello")); // 31 hash
    try testing.expect(!isStoreEntryName("00000000000000000000000000000000")); // no dash/name
    try testing.expect(!isStoreEntryName("00000000000000000000000000000000-")); // empty name
    try testing.expect(!isStoreEntryName("0000000000000000000000000000000e-hello")); // 'e' not base32
}

test "gc keeps the root closure and frees the rest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const store = try std.fs.path.resolve(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "store" });
    defer testing.allocator.free(store);
    const gcroots = try std.fs.path.resolve(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "gcroots" });
    defer testing.allocator.free(gcroots);
    try std.Io.Dir.cwd().createDirPath(testing.io, gcroots);

    const a_name = "00000000000000000000000000000000-a";
    const b_name = "11111111111111111111111111111111-b";
    const c_name = "22222222222222222222222222222222-c";

    const b_path = try absStorePath(testing.allocator, store, b_name);
    defer testing.allocator.free(b_path);
    // a references b; c is unreferenced.
    const a_content = try std.fmt.allocPrint(testing.allocator, "dep = {s}\n", .{b_path});
    defer testing.allocator.free(a_content);

    const a_path = try absStorePath(testing.allocator, store, a_name);
    defer testing.allocator.free(a_path);
    const c_path = try absStorePath(testing.allocator, store, c_name);
    defer testing.allocator.free(c_path);
    try writeFileAt(testing.io, testing.allocator, a_path, a_content);
    try writeFileAt(testing.io, testing.allocator, b_path, "leaf\n");
    try writeFileAt(testing.io, testing.allocator, c_path, "garbage\n");

    // gcroots/auto -> a
    const root_link = try std.fs.path.join(testing.allocator, &.{ gcroots, "auto-link" });
    defer testing.allocator.free(root_link);
    try std.Io.Dir.cwd().symLink(testing.io, a_path, root_link, .{});

    var gc = try Gc.init(testing.allocator, testing.io, store, gcroots);
    defer gc.deinit();
    _ = try gc.addIndirectRoots();
    var report = try gc.run(false);
    defer report.deinit();

    try testing.expectEqual(@as(usize, 2), report.live_count); // a + b
    try testing.expectEqual(@as(usize, 1), report.freedCount());
    try testing.expectEqualStrings(c_path, report.freed.items[0]);
    try testing.expect(exists(testing.io, a_path));
    try testing.expect(exists(testing.io, b_path));
    try testing.expect(!exists(testing.io, c_path));
}

test "gc dry run reports without deleting" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const store = try std.fs.path.resolve(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "store" });
    defer testing.allocator.free(store);
    const gcroots = try std.fs.path.resolve(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "gcroots" });
    defer testing.allocator.free(gcroots);
    try std.Io.Dir.cwd().createDirPath(testing.io, gcroots);

    const dead_name = "33333333333333333333333333333333-dead";
    const dead_path = try absStorePath(testing.allocator, store, dead_name);
    defer testing.allocator.free(dead_path);
    try writeFileAt(testing.io, testing.allocator, dead_path, "keep me during dry run\n");

    var gc = try Gc.init(testing.allocator, testing.io, store, gcroots);
    defer gc.deinit();
    var report = try gc.run(true);
    defer report.deinit();

    try testing.expectEqual(@as(usize, 1), report.freedCount());
    try testing.expect(report.freed_bytes > 0);
    try testing.expect(exists(testing.io, dead_path));
}

test "gc removes an unreachable directory tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const store = try std.fs.path.resolve(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "store" });
    defer testing.allocator.free(store);
    const gcroots = try std.fs.path.resolve(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "gcroots" });
    defer testing.allocator.free(gcroots);
    try std.Io.Dir.cwd().createDirPath(testing.io, gcroots);

    const dir_name = "44444444444444444444444444444444-tree";
    const dir_path = try absStorePath(testing.allocator, store, dir_name);
    defer testing.allocator.free(dir_path);
    const nested = try std.fs.path.join(testing.allocator, &.{ dir_path, "sub", "file" });
    defer testing.allocator.free(nested);
    try writeFileAt(testing.io, testing.allocator, nested, "nested payload\n");

    var gc = try Gc.init(testing.allocator, testing.io, store, gcroots);
    defer gc.deinit();
    var report = try gc.run(false);
    defer report.deinit();

    try testing.expectEqual(@as(usize, 1), report.freedCount());
    try testing.expect(!exists(testing.io, dir_path));
}

test "gc ignores non-entry files in the store" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const store = try std.fs.path.resolve(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "store" });
    defer testing.allocator.free(store);
    const gcroots = try std.fs.path.resolve(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "gcroots" });
    defer testing.allocator.free(gcroots);
    try std.Io.Dir.cwd().createDirPath(testing.io, gcroots);

    const socket_path = try std.fs.path.join(testing.allocator, &.{ store, "socket" });
    defer testing.allocator.free(socket_path);
    try writeFileAt(testing.io, testing.allocator, socket_path, "");

    var gc = try Gc.init(testing.allocator, testing.io, store, gcroots);
    defer gc.deinit();
    var report = try gc.run(false);
    defer report.deinit();

    try testing.expectEqual(@as(usize, 0), report.freedCount());
    try testing.expect(exists(testing.io, socket_path));
}
