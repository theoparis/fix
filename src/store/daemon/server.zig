//! Nix-compatible worker-protocol daemon server.
//!
//! Provides a standalone or in-process daemon implementation capable of
//! receiving store additions (.drv files, text, NAR archives) and executing
//! derivation builds in a local store directory (e.g. `.fix/store` or `/nix/store`).

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("base").sync;
const owned_strings = @import("base").owned_strings;
const wire = @import("wire.zig");
const sandbox = @import("sandbox.zig");

var global_build_counter: std.atomic.Value(u64) = .init(1);

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir: []const u8,
    socket_path: []const u8,
    sandbox_mode: sandbox.SandboxMode = .none,
    chroot_dir: ?[]const u8 = null,
    server: ?std.Io.net.Server = null,
    thread: ?std.Thread = null,
    conn_threads: std.ArrayListUnmanaged(std.Thread) = .empty,
    shutdown: std.atomic.Value(bool) = .init(false),
    mu: sync.BlockingMutex = .{},
    valid_paths: std.StringHashMapUnmanaged(void) = .empty,
    queried_names: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub const Options = struct {
        store_dir: []const u8 = ".fix/store",
        socket_path: ?[]const u8 = null,
        sandbox_mode: sandbox.SandboxMode = .none,
        chroot_dir: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);

        const owned_store_dir = if (std.fs.path.isAbsolute(options.store_dir))
            try allocator.dupe(u8, options.store_dir)
        else
            try std.fs.path.resolve(allocator, &.{ cwd, options.store_dir });
        errdefer allocator.free(owned_store_dir);

        const socket_path = if (options.socket_path) |sock|
            (if (std.fs.path.isAbsolute(sock))
                try allocator.dupe(u8, sock)
            else
                try std.fs.path.resolve(allocator, &.{ cwd, sock }))
        else
            try std.fs.path.join(allocator, &.{ owned_store_dir, "socket" });
        errdefer allocator.free(socket_path);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .store_dir = owned_store_dir,
            .socket_path = socket_path,
            .sandbox_mode = options.sandbox_mode,
            .chroot_dir = if (options.chroot_dir) |c| try allocator.dupe(u8, c) else null,
        };

        // Ensure store directory exists
        try std.Io.Dir.cwd().createDirPath(io, self.store_dir);

        return self;
    }

    pub fn deinit(self: *Server) void {
        if (self.chroot_dir) |c| self.allocator.free(c);
        self.shutdown.store(true, .release);
        if (self.server) |*srv| {
            // Wake accept loop if running
            if (self.socket_path.len != 0) {
                if (std.Io.net.UnixAddress.init(self.socket_path)) |addr| {
                    if (addr.connect(self.io)) |stream| stream.close(self.io) else |_| {}
                } else |_| {}
            }
            if (self.thread) |t| t.join();
            for (self.conn_threads.items) |t| t.join();
            self.conn_threads.deinit(self.allocator);
            srv.socket.close(self.io);
            if (self.socket_path.len != 0 and self.socket_path[0] != 0) {
                std.Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};
            }
        }
        self.mu.lock();
        var valid_it = self.valid_paths.keyIterator();
        while (valid_it.next()) |p| self.allocator.free(p.*);
        self.valid_paths.deinit(self.allocator);

        var query_it = self.queried_names.iterator();
        while (query_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.queried_names.deinit(self.allocator);
        self.mu.unlock();

        self.allocator.free(self.store_dir);
        self.allocator.free(self.socket_path);
        self.allocator.destroy(self);
    }

    pub fn listenAndServe(self: *Server) !void {
        // Ensure parent directory for socket exists
        if (std.fs.path.dirname(self.socket_path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(self.io, parent);
        }

        // Delete existing socket if present
        std.Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};

        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        var server = try address.listen(self.io, .{});
        self.server = server;

        while (!self.shutdown.load(.acquire)) {
            const stream = server.accept(self.io) catch |err| {
                if (self.shutdown.load(.acquire)) break;
                return err;
            };
            if (self.shutdown.load(.acquire)) {
                stream.close(self.io);
                break;
            }
            const t = try std.Thread.spawn(.{}, serveConn, .{ self, stream });
            self.mu.lock();
            self.conn_threads.append(self.allocator, t) catch {
                t.detach();
            };
            self.mu.unlock();
        }
    }

    pub fn serveStream(self: *Server, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        if ((try wire.readInt(input)) != wire.worker_magic_1) return error.WorkerMagicMismatch;
        try wire.writeInt(output, wire.worker_magic_2);
        try wire.writeInt(output, wire.protocol_version);
        try output.flush();

        _ = try wire.readInt(input); // client protocol version
        _ = try wire.readInt(input); // obsolete CPU affinity
        _ = try wire.readInt(input); // obsolete reserveSpace
        try wire.writeString(output, "fix-daemon");
        try wire.writeInt(output, 1); // trusted
        try wire.writeInt(output, wire.stderr_last);
        try output.flush();

        while (!self.shutdown.load(.acquire)) {
            const raw_op = wire.readInt(input) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            const op = std.enums.fromInt(wire.Op, raw_op) orelse {
                return writeDaemonError(output, "unsupported worker protocol operation");
            };
            switch (op) {
                .set_options => try self.handleSetOptions(input, output),
                .is_valid_path => try self.handleIsValid(input, output),
                .query_missing => try self.handleQueryMissing(input, output),
                .add_to_store => try self.handleAdd(input, output),
                .add_text_to_store => try self.handleAddText(input, output),
                .build_paths => try self.handleBuild(input, output),
                .add_indirect_root, .add_temp_root => try self.handleRoots(input, output),
                .nar_from_path => try self.handleNarFromPath(input, output),
                else => {
                    try writeDaemonError(output, "unsupported worker protocol operation");
                },
            }
        }
    }

    fn serveConn(self: *Server, stream: std.Io.net.Stream) void {
        defer stream.close(self.io);
        var read_buffer: [64 * 1024]u8 = undefined;
        var write_buffer: [64 * 1024]u8 = undefined;
        var reader = std.Io.net.Stream.Reader.init(stream, self.io, &read_buffer);
        var writer = std.Io.net.Stream.Writer.init(stream, self.io, &write_buffer);
        self.serveStream(&reader.interface, &writer.interface) catch |err| {
            if (err != error.EndOfStream) {
                std.debug.print("daemon conn error: {s}\n", .{@errorName(err)});
            }
        };
    }

    fn handleSetOptions(self: *Server, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        _ = try wire.readBool(input); // keep_failed
        _ = try wire.readBool(input); // keep_going
        _ = try wire.readBool(input); // fallback
        _ = try wire.readInt(input); // verbosity
        _ = try wire.readInt(input); // max_build_jobs
        _ = try wire.readInt(input); // max_silent_time
        _ = try wire.readInt(input); // use_build_hook
        _ = try wire.readInt(input); // verbose_build
        _ = try wire.readInt(input); // log_type
        _ = try wire.readInt(input); // print_build_trace
        _ = try wire.readInt(input); // build_cores
        _ = try wire.readBool(input); // use_substitutes
        const count = try wire.readInt(input);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const name = try wire.readString(self.allocator, input);
            defer self.allocator.free(name);
            const val = try wire.readString(self.allocator, input);
            defer self.allocator.free(val);
        }
        try wire.writeInt(output, wire.stderr_last);
        try output.flush();
    }

    fn handleIsValid(self: *Server, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        const path = try wire.readString(self.allocator, input);
        defer self.allocator.free(path);

        const base = std.fs.path.basename(path);
        const name = if (base.len > 33 and base[32] == '-') base[33..] else base;

        self.mu.lock();
        // Remember query mapping
        if (!self.queried_names.contains(name)) {
            const owned_k = try self.allocator.dupe(u8, name);
            const owned_v = try self.allocator.dupe(u8, path);
            self.queried_names.put(self.allocator, owned_k, owned_v) catch {};
        }
        var valid = self.valid_paths.contains(path);
        self.mu.unlock();

        if (!valid) {
            // Check filesystem
            valid = self.pathExists(path);
            if (valid) {
                self.mu.lock();
                const owned = self.allocator.dupe(u8, path) catch null;
                if (owned) |p| self.valid_paths.put(self.allocator, p, {}) catch {};
                self.mu.unlock();
            }
        }

        try wire.writeInt(output, wire.stderr_last);
        try wire.writeBool(output, valid);
        try output.flush();
    }

    fn handleQueryMissing(self: *Server, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        const paths = try wire.readStrings(self.allocator, input);
        defer owned_strings.free(self.allocator, paths);

        var will_build: std.ArrayListUnmanaged([]const u8) = .empty;
        defer will_build.deinit(self.allocator);

        for (paths) |p| {
            if (!self.pathExists(p)) {
                try will_build.append(self.allocator, p);
            }
        }

        try wire.writeInt(output, wire.stderr_last);
        try wire.writeStrings(output, will_build.items);
        try wire.writeStrings(output, &.{}); // will_substitute
        try wire.writeStrings(output, &.{}); // unknown
        try wire.writeInt(output, 0); // download_size
        try wire.writeInt(output, 0); // nar_size
        try output.flush();
    }

    fn handleAdd(self: *Server, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        const name = try wire.readString(self.allocator, input);
        defer self.allocator.free(name);
        const content_address = try wire.readString(self.allocator, input);
        defer self.allocator.free(content_address);
        const references = try wire.readStrings(self.allocator, input);
        defer owned_strings.free(self.allocator, references);
        _ = try wire.readBool(input); // repair
        const payload = try readFramed(self.allocator, input);
        defer self.allocator.free(payload);

        self.mu.lock();
        const queried = if (self.queried_names.get(name)) |q| try self.allocator.dupe(u8, q) else null;
        self.mu.unlock();
        defer if (queried) |q| self.allocator.free(q);

        const client_path = queried orelse try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.store_dir, name });
        defer if (queried == null) self.allocator.free(client_path);

        const local_path = try self.toLocalPath(client_path);
        defer self.allocator.free(local_path);

        if (std.mem.eql(u8, content_address, "fixed:r:sha256")) {
            // NAR unpack
            var slice_reader = std.Io.Reader.fixed(payload);
            unpackNar(self.allocator, self.io, &slice_reader, local_path) catch |err| {
                return writeDaemonError(output, @errorName(err));
            };
        } else {
            // Flat file or text
            try writeStoreFile(self.io, local_path, payload);
        }

        self.mu.lock();
        const owned = self.allocator.dupe(u8, client_path) catch null;
        if (owned) |p| self.valid_paths.put(self.allocator, p, {}) catch {};
        self.mu.unlock();

        try wire.writeInt(output, wire.stderr_last);
        try writeValidPathInfo(output, client_path);
        try output.flush();
    }

    fn handleAddText(self: *Server, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        const name = try wire.readString(self.allocator, input);
        defer self.allocator.free(name);
        const text = try wire.readString(self.allocator, input);
        defer self.allocator.free(text);
        const references = try wire.readStrings(self.allocator, input);
        defer owned_strings.free(self.allocator, references);

        self.mu.lock();
        const queried = if (self.queried_names.get(name)) |q| try self.allocator.dupe(u8, q) else null;
        self.mu.unlock();
        defer if (queried) |q| self.allocator.free(q);

        const client_path = queried orelse try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.store_dir, name });
        defer if (queried == null) self.allocator.free(client_path);

        const local_path = try self.toLocalPath(client_path);
        defer self.allocator.free(local_path);

        try writeStoreFile(self.io, local_path, text);

        self.mu.lock();
        const owned = self.allocator.dupe(u8, client_path) catch null;
        if (owned) |p| self.valid_paths.put(self.allocator, p, {}) catch {};
        self.mu.unlock();

        try wire.writeInt(output, wire.stderr_last);
        try wire.writeString(output, client_path);
        try output.flush();
    }

    fn handleBuild(self: *Server, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        const paths = try wire.readStrings(self.allocator, input);
        defer owned_strings.free(self.allocator, paths);
        _ = try wire.readInt(input); // build mode

        for (paths) |p| {
            try self.buildDerivationPath(p, output);
        }

        try wire.writeInt(output, wire.stderr_last);
        try wire.writeInt(output, 1);
        try output.flush();
    }

    fn handleRoots(self: *Server, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        _ = self;
        const link_path = try wire.readString(std.heap.page_allocator, input);
        defer std.heap.page_allocator.free(link_path);
        try wire.writeInt(output, wire.stderr_last);
        try wire.writeInt(output, 1);
        try output.flush();
    }

    fn handleNarFromPath(self: *Server, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        const path = try wire.readString(self.allocator, input);
        defer self.allocator.free(path);

        try wire.writeInt(output, wire.stderr_last);
        var file_cache = @import("../file_cache.zig").FileCache.init(self.allocator);
        defer file_cache.deinit();
        const nar_bytes = try @import("../nar.zig").serialize(self.allocator, &file_cache, path, null);
        defer self.allocator.free(nar_bytes);
        try output.writeAll(nar_bytes);
        try output.flush();
    }

    fn toLocalPath(self: *Server, path: []const u8) ![]u8 {
        const cwd = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd);

        var abs_path: []u8 = undefined;
        if (std.fs.path.isAbsolute(path)) {
            abs_path = try self.allocator.dupe(u8, path);
        } else {
            abs_path = try std.fs.path.resolve(self.allocator, &.{ cwd, path });
        }
        defer self.allocator.free(abs_path);

        if (std.mem.startsWith(u8, abs_path, "/nix/store/") and !std.mem.eql(u8, self.store_dir, "/nix/store")) {
            return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.store_dir, abs_path["/nix/store/".len..] });
        }
        return self.allocator.dupe(u8, abs_path);
    }

    fn pathExists(self: *Server, raw_path: []const u8) bool {
        const local = self.toLocalPath(raw_path) catch return false;
        defer self.allocator.free(local);
        const file = std.Io.Dir.openFileAbsolute(self.io, local, .{}) catch |err| switch (err) {
            error.IsDir => return true,
            else => return false,
        };
        file.close(self.io);
        return true;
    }

    fn resolveTargetPath(self: *Server, name: []const u8) ![]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.queried_names.get(name)) |queried| {
            return self.toLocalPath(queried);
        }
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.store_dir, name });
    }

    fn buildDerivationPath(self: *Server, raw_path: []const u8, output: *std.Io.Writer) !void {
        // Strip !<output> if present
        const drv_path = if (std.mem.indexOfScalar(u8, raw_path, '!')) |idx|
            raw_path[0..idx]
        else
            raw_path;

        if (!std.mem.endsWith(u8, drv_path, ".drv")) {
            if (self.pathExists(drv_path)) return;
            return writeDaemonError(output, "expected .drv path for build");
        }

        const local_drv_path = try self.toLocalPath(drv_path);
        defer self.allocator.free(local_drv_path);

        // Read .drv file content
        const drv_content = std.Io.Dir.cwd().readFileAlloc(self.io, local_drv_path, self.allocator, .limited(10 * 1024 * 1024)) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "cannot read derivation '{s}': {s}", .{ local_drv_path, @errorName(err) });
            defer self.allocator.free(msg);
            return writeDaemonError(output, msg);
        };
        defer self.allocator.free(drv_content);

        var parsed = parseATerm(self.allocator, drv_content) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "failed to parse derivation ATerm in '{s}': {s}", .{ drv_path, @errorName(err) });
            defer self.allocator.free(msg);
            return writeDaemonError(output, msg);
        };
        defer parsed.deinit();

        // Recursively build input drvs
        for (parsed.input_drvs) |input_drv| {
            try self.buildDerivationPath(input_drv.path, output);
        }

        // Check if all outputs already exist
        var all_outputs_exist = parsed.outputs.len > 0;
        for (parsed.outputs) |out| {
            if (out.path.len == 0 or !self.pathExists(out.path)) {
                all_outputs_exist = false;
                break;
            }
        }
        if (all_outputs_exist) return;

        // Log starting build
        const log_msg = try std.fmt.allocPrint(self.allocator, "building '{s}'...\n", .{drv_path});
        defer self.allocator.free(log_msg);
        try wire.writeInt(output, wire.stderr_next);
        try wire.writeString(output, log_msg);
        try output.flush();

        // Create fresh unique temporary build directory
        const id = global_build_counter.fetchAdd(1, .monotonic);
        const timestamp = std.Io.Clock.real.now(self.io).toMilliseconds();
        const build_dir = try std.fmt.allocPrint(self.allocator, "/tmp/fix-build-{d}-{d}-{d}", .{ std.Thread.getCurrentId(), timestamp, id });
        defer {
            std.Io.Dir.cwd().deleteTree(self.io, build_dir) catch {};
            self.allocator.free(build_dir);
        }
        std.Io.Dir.cwd().deleteTree(self.io, build_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(self.io, build_dir);

        // Ensure parent dirs for all outputs exist
        for (parsed.outputs) |out| {
            if (out.path.len > 0) {
                const local_out = try self.toLocalPath(out.path);
                defer self.allocator.free(local_out);
                if (std.fs.path.dirname(local_out)) |parent| {
                    try std.Io.Dir.cwd().createDirPath(self.io, parent);
                }
            }
        }

        // Setup environment map
        var env = std.process.Environ.Map.init(self.allocator);
        defer env.deinit();

        // Copy host PATH or provide default
        var path_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer path_buf.deinit(self.allocator);

        // Standard PATH for builders
        try path_buf.appendSlice(self.allocator, "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin");
        if (std.c.getenv("PATH")) |host_path_ptr| {
            try path_buf.append(self.allocator, ':');
            try path_buf.appendSlice(self.allocator, std.mem.span(host_path_ptr));
        }

        try env.put("PATH", path_buf.items);
        try env.put("TMPDIR", build_dir);
        try env.put("TEMP", build_dir);
        try env.put("TMP", build_dir);
        try env.put("NIX_BUILD_TOP", build_dir);
        try env.put("PWD", build_dir);
        try env.put("NIX_STORE", self.store_dir);

        // Nix-compatible build concurrency hint, expected by the stdenv and
        // many upstream build systems (e.g. `make -j$NIX_BUILD_CORES`).
        {
            const cpu_count = std.Thread.getCpuCount() catch 1;
            const cores = try std.fmt.allocPrint(self.allocator, "{d}", .{cpu_count});
            defer self.allocator.free(cores);
            try env.put("NIX_BUILD_CORES", cores);
        }

        for (parsed.env) |e| {
            var val = try self.allocator.dupe(u8, e.value);
            defer self.allocator.free(val);

            if (std.mem.indexOf(u8, val, "/nix/store") != null and !std.mem.eql(u8, self.store_dir, "/nix/store")) {
                const replaced = try std.mem.replaceOwned(u8, self.allocator, val, "/nix/store", self.store_dir);
                self.allocator.free(val);
                val = replaced;
            }
            if (std.mem.indexOf(u8, val, ".fix/store") != null) {
                const replaced = try std.mem.replaceOwned(u8, self.allocator, val, ".fix/store", self.store_dir);
                self.allocator.free(val);
                val = replaced;
            }
            try env.put(e.name, val);
        }

        // Prepare argv: builder + args
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, parsed.builder);
        for (parsed.args) |a| {
            if (std.mem.indexOf(u8, a, ".fix/store") != null) {
                const replaced = try std.mem.replaceOwned(u8, self.allocator, a, ".fix/store", self.store_dir);
                try argv.append(self.allocator, replaced);
            } else if (std.mem.indexOf(u8, a, "/nix/store") != null and !std.mem.eql(u8, self.store_dir, "/nix/store")) {
                const replaced = try std.mem.replaceOwned(u8, self.allocator, a, "/nix/store", self.store_dir);
                try argv.append(self.allocator, replaced);
            } else {
                try argv.append(self.allocator, a);
            }
        }

        // Determine if fixed-output or network allowed
        var allow_network = false;
        for (parsed.env) |e| {
            if (std.mem.eql(u8, e.name, "outputHash") or std.mem.eql(u8, e.name, "__noChroot") or std.mem.eql(u8, e.name, "impure")) {
                allow_network = true;
            }
        }

        var output_paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (output_paths.items) |p| self.allocator.free(p);
            output_paths.deinit(self.allocator);
        }
        for (parsed.outputs) |out| {
            if (out.path.len > 0) {
                const local_out = try self.toLocalPath(out.path);
                try output_paths.append(self.allocator, local_out);
            }
        }

        const sandbox_opts = sandbox.SandboxOptions{
            .mode = self.sandbox_mode,
            .store_dir = self.store_dir,
            .build_dir = build_dir,
            .output_paths = output_paths.items,
            .allow_network = allow_network,
            .chroot_dir = self.chroot_dir,
        };

        const final_argv = try sandbox.wrapArgv(self.allocator, sandbox_opts, argv.items);
        defer self.allocator.free(final_argv);

        var child = std.process.spawn(self.io, .{
            .argv = final_argv,
            .environ_map = &env,
            .cwd = .{ .path = build_dir },
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "builder for '{s}' failed to spawn: {s}", .{ drv_path, @errorName(err) });
            defer self.allocator.free(msg);
            return writeDaemonError(output, msg);
        };

        // Concurrently pump stdout and stderr to prevent pipe buffer deadlock
        const StreamPump = struct {
            pump_io: std.Io,
            pump_file: std.Io.File,
            pump_output: *std.Io.Writer,
            pump_mu: *sync.BlockingMutex,

            fn run(pump: *@This()) void {
                var stream_buf: [4096]u8 = undefined;
                var r = pump.pump_file.readerStreaming(pump.pump_io, &stream_buf);
                while (true) {
                    var chunk_buf: [1024]u8 = undefined;
                    const n = r.interface.readSliceShort(&chunk_buf) catch break;
                    if (n == 0) break;
                    pump.pump_mu.lock();
                    wire.writeInt(pump.pump_output, wire.stderr_next) catch {
                        pump.pump_mu.unlock();
                        break;
                    };
                    wire.writeString(pump.pump_output, chunk_buf[0..n]) catch {
                        pump.pump_mu.unlock();
                        break;
                    };
                    pump.pump_output.flush() catch {
                        pump.pump_mu.unlock();
                        break;
                    };
                    pump.pump_mu.unlock();
                }
            }
        };

        var stream_mu: sync.BlockingMutex = .{};
        var stderr_pump: ?StreamPump = if (child.stderr) |f| StreamPump{
            .pump_io = self.io,
            .pump_file = f,
            .pump_output = output,
            .pump_mu = &stream_mu,
        } else null;

        const stderr_thread: ?std.Thread = if (stderr_pump) |*p|
            std.Thread.spawn(.{}, StreamPump.run, .{p}) catch null
        else
            null;

        if (child.stdout) |stdout_file| {
            var stdout_pump = StreamPump{
                .pump_io = self.io,
                .pump_file = stdout_file,
                .pump_output = output,
                .pump_mu = &stream_mu,
            };
            stdout_pump.run();
        }

        if (stderr_thread) |t| t.join();

        const term = child.wait(self.io) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "builder for '{s}' error while waiting: {s}", .{ drv_path, @errorName(err) });
            defer self.allocator.free(msg);
            return writeDaemonError(output, msg);
        };

        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    const msg = try std.fmt.allocPrint(self.allocator, "builder for '{s}' failed with exit code {d}", .{ drv_path, code });
                    defer self.allocator.free(msg);
                    return writeDaemonError(output, msg);
                }
            },
            else => {
                const msg = try std.fmt.allocPrint(self.allocator, "builder for '{s}' terminated abnormally", .{drv_path});
                defer self.allocator.free(msg);
                return writeDaemonError(output, msg);
            },
        }

        // Verify that outputs exist
        for (parsed.outputs) |out| {
            if (out.path.len > 0) {
                const local_out = try self.toLocalPath(out.path);
                defer self.allocator.free(local_out);
                if (!self.pathExists(local_out)) {
                    const msg = try std.fmt.allocPrint(self.allocator, "builder for '{s}' did not produce expected output path '{s}'", .{ drv_path, local_out });
                    defer self.allocator.free(msg);
                    return writeDaemonError(output, msg);
                }
                self.mu.lock();
                const owned = self.allocator.dupe(u8, out.path) catch null;
                if (owned) |p| self.valid_paths.put(self.allocator, p, {}) catch {};
                self.mu.unlock();
            }
        }
    }
};

fn writeStoreFile(io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var w = file.writerStreaming(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

fn readFramed(allocator: std.mem.Allocator, input: *std.Io.Reader) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);
    while (true) {
        const len = try wire.readInt(input);
        if (len == 0) return result.toOwnedSlice(allocator);
        if (len > wire.max_wire_len) return error.WireStringTooLong;
        const old_len = result.items.len;
        try result.resize(allocator, old_len + @as(usize, @intCast(len)));
        try input.readSliceAll(result.items[old_len..]);
    }
}

fn writeDaemonError(output: *std.Io.Writer, message: []const u8) !void {
    try wire.writeInt(output, wire.stderr_error);
    try wire.writeString(output, "Error");
    try wire.writeInt(output, 0);
    try wire.writeString(output, "Error");
    try wire.writeString(output, message);
    try wire.writeInt(output, 0); // no position
    try wire.writeInt(output, 0); // no traces
    try output.flush();
}

fn writeValidPathInfo(output: *std.Io.Writer, path: []const u8) !void {
    try wire.writeString(output, path);
    try wire.writeString(output, ""); // deriver
    try wire.writeString(output, "sha256:fake");
    try wire.writeStrings(output, &.{});
    try wire.writeInt(output, 0); // registration time
    try wire.writeInt(output, 0); // NAR size
    try wire.writeInt(output, 0); // ultimate
    try wire.writeStrings(output, &.{}); // signatures
    try wire.writeString(output, ""); // content address
}

// --- NAR Unpacker -----------------------------------------------------------

fn expectToken(allocator: std.mem.Allocator, reader: *std.Io.Reader, want: []const u8) !void {
    const token = try wire.readString(allocator, reader);
    defer allocator.free(token);
    if (!std.mem.eql(u8, token, want)) return error.UnexpectedNar;
}

fn unpackNarNode(allocator: std.mem.Allocator, io: std.Io, reader: *std.Io.Reader, target_path: []const u8) !void {
    try expectToken(allocator, reader, "(");
    try expectToken(allocator, reader, "type");
    const node_type = try wire.readString(allocator, reader);
    defer allocator.free(node_type);

    if (std.mem.eql(u8, node_type, "regular")) {
        var is_exec = false;
        var token = try wire.readString(allocator, reader);
        if (std.mem.eql(u8, token, "executable")) {
            allocator.free(token);
            const empty = try wire.readString(allocator, reader);
            allocator.free(empty);
            token = try wire.readString(allocator, reader);
            is_exec = true;
        }
        defer allocator.free(token);
        if (!std.mem.eql(u8, token, "contents")) return error.UnexpectedNar;

        const contents = try wire.readString(allocator, reader);
        defer allocator.free(contents);
        try expectToken(allocator, reader, ")");

        try writeStoreFile(io, target_path, contents);
        if (is_exec) {
            const f = try std.Io.Dir.openFileAbsolute(io, target_path, .{ .mode = .read_write });
            defer f.close(io);
            try f.setPermissions(io, .executable_file);
        }
    } else if (std.mem.eql(u8, node_type, "directory")) {
        try std.Io.Dir.cwd().createDirPath(io, target_path);
        while (true) {
            const token = try wire.readString(allocator, reader);
            defer allocator.free(token);
            if (std.mem.eql(u8, token, ")")) break;
            if (!std.mem.eql(u8, token, "entry")) return error.UnexpectedNar;
            try expectToken(allocator, reader, "(");
            try expectToken(allocator, reader, "name");
            const entry_name = try wire.readString(allocator, reader);
            defer allocator.free(entry_name);
            try expectToken(allocator, reader, "node");
            const child_path = try std.fs.path.join(allocator, &.{ target_path, entry_name });
            defer allocator.free(child_path);
            try unpackNarNode(allocator, io, reader, child_path);
            try expectToken(allocator, reader, ")");
        }
    } else if (std.mem.eql(u8, node_type, "symlink")) {
        try expectToken(allocator, reader, "target");
        const target = try wire.readString(allocator, reader);
        defer allocator.free(target);
        try expectToken(allocator, reader, ")");
        if (std.fs.path.dirname(target_path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        try std.Io.Dir.cwd().symLink(io, target, target_path, .{});
    } else {
        return error.UnsupportedNarNodeType;
    }
}

pub fn unpackNar(allocator: std.mem.Allocator, io: std.Io, reader: *std.Io.Reader, target_path: []const u8) !void {
    try expectToken(allocator, reader, "nix-archive-1");
    try unpackNarNode(allocator, io, reader, target_path);
}

// --- ATerm Parser for Derivations -------------------------------------------

pub const ParsedOutput = struct {
    name: []const u8,
    path: []const u8,
    hash_algo: []const u8,
    hash: []const u8,
};

pub const ParsedInputDrv = struct {
    path: []const u8,
    outputs: [][]const u8,
};

pub const ParsedEnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const ParsedDrv = struct {
    arena: std.heap.ArenaAllocator,
    outputs: []ParsedOutput,
    input_drvs: []ParsedInputDrv,
    input_srcs: [][]const u8,
    system: []const u8,
    builder: []const u8,
    args: [][]const u8,
    env: []ParsedEnvVar,

    pub fn deinit(self: *ParsedDrv) void {
        self.arena.deinit();
    }
};

const AtermParser = struct {
    text: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    fn skipWhitespace(self: *AtermParser) void {
        while (self.pos < self.text.len) : (self.pos += 1) {
            switch (self.text[self.pos]) {
                ' ', '\t', '\r', '\n' => {},
                else => break,
            }
        }
    }

    fn peek(self: *AtermParser) ?u8 {
        self.skipWhitespace();
        if (self.pos < self.text.len) return self.text[self.pos];
        return null;
    }

    fn expect(self: *AtermParser, token: []const u8) !void {
        self.skipWhitespace();
        if (self.pos + token.len <= self.text.len and std.mem.eql(u8, self.text[self.pos .. self.pos + token.len], token)) {
            self.pos += token.len;
            return;
        }
        return error.InvalidAterm;
    }

    fn parseString(self: *AtermParser) ![]const u8 {
        self.skipWhitespace();
        try self.expect("\"");
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        while (self.pos < self.text.len) {
            const ch = self.text[self.pos];
            self.pos += 1;
            if (ch == '"') {
                return buf.toOwnedSlice(self.allocator);
            } else if (ch == '\\') {
                if (self.pos >= self.text.len) return error.InvalidAterm;
                const esc = self.text[self.pos];
                self.pos += 1;
                switch (esc) {
                    '"' => try buf.append(self.allocator, '"'),
                    '\\' => try buf.append(self.allocator, '\\'),
                    'n' => try buf.append(self.allocator, '\n'),
                    'r' => try buf.append(self.allocator, '\r'),
                    't' => try buf.append(self.allocator, '\t'),
                    else => try buf.append(self.allocator, esc),
                }
            } else {
                try buf.append(self.allocator, ch);
            }
        }
        return error.InvalidAterm;
    }

    fn parseStringList(self: *AtermParser) ![][]const u8 {
        try self.expect("[");
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer list.deinit(self.allocator);

        while (self.peek()) |ch| {
            if (ch == ']') {
                try self.expect("]");
                break;
            }
            const s = try self.parseString();
            try list.append(self.allocator, s);
            if (self.peek() == ',') try self.expect(",");
        }
        return list.toOwnedSlice(self.allocator);
    }

    fn parseOutputs(self: *AtermParser) ![]ParsedOutput {
        try self.expect("[");
        var list: std.ArrayListUnmanaged(ParsedOutput) = .empty;
        errdefer list.deinit(self.allocator);

        while (self.peek()) |ch| {
            if (ch == ']') {
                try self.expect("]");
                break;
            }
            try self.expect("(");
            const name = try self.parseString();
            try self.expect(",");
            const path = try self.parseString();
            try self.expect(",");
            const algo = try self.parseString();
            try self.expect(",");
            const hash = try self.parseString();
            try self.expect(")");
            try list.append(self.allocator, .{ .name = name, .path = path, .hash_algo = algo, .hash = hash });
            if (self.peek() == ',') try self.expect(",");
        }
        return list.toOwnedSlice(self.allocator);
    }

    fn parseInputDrvs(self: *AtermParser) ![]ParsedInputDrv {
        try self.expect("[");
        var list: std.ArrayListUnmanaged(ParsedInputDrv) = .empty;
        errdefer list.deinit(self.allocator);

        while (self.peek()) |ch| {
            if (ch == ']') {
                try self.expect("]");
                break;
            }
            try self.expect("(");
            const drv_path = try self.parseString();
            try self.expect(",");
            const outputs = try self.parseStringList();
            try self.expect(")");
            try list.append(self.allocator, .{ .path = drv_path, .outputs = outputs });
            if (self.peek() == ',') try self.expect(",");
        }
        return list.toOwnedSlice(self.allocator);
    }

    fn parseEnv(self: *AtermParser) ![]ParsedEnvVar {
        try self.expect("[");
        var list: std.ArrayListUnmanaged(ParsedEnvVar) = .empty;
        errdefer list.deinit(self.allocator);

        while (self.peek()) |ch| {
            if (ch == ']') {
                try self.expect("]");
                break;
            }
            try self.expect("(");
            const k = try self.parseString();
            try self.expect(",");
            const v = try self.parseString();
            try self.expect(")");
            try list.append(self.allocator, .{ .name = k, .value = v });
            if (self.peek() == ',') try self.expect(",");
        }
        return list.toOwnedSlice(self.allocator);
    }
};

pub fn parseATerm(parent_allocator: std.mem.Allocator, text: []const u8) !ParsedDrv {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var parser: AtermParser = .{
        .text = text,
        .allocator = allocator,
    };

    try parser.expect("Derive(");
    const outputs = try parser.parseOutputs();
    try parser.expect(",");
    const input_drvs = try parser.parseInputDrvs();
    try parser.expect(",");
    const input_srcs = try parser.parseStringList();
    try parser.expect(",");
    const system = try parser.parseString();
    try parser.expect(",");
    const builder = try parser.parseString();
    try parser.expect(",");
    const args = try parser.parseStringList();
    try parser.expect(",");
    const env = try parser.parseEnv();
    try parser.expect(")");

    return .{
        .arena = arena,
        .outputs = outputs,
        .input_drvs = input_drvs,
        .input_srcs = input_srcs,
        .system = system,
        .builder = builder,
        .args = args,
        .env = env,
    };
}
