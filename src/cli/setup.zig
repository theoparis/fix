//! Shared evaluator setup for the eval-producing subcommands (`eval`, `repl`,
//! `instantiate`, `build`, and `run`). Owns the worker-count formula and
//! the `Options → Engine` configuration block that each subcommand would
//! otherwise duplicate.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("expr");
const store = @import("store");
const presentation = @import("presentation.zig");
const render = @import("render.zig");
const args = @import("args.zig");
const nix_conf = @import("nix_conf.zig");
const hugetlb = @import("base").hugetlb;
const effect_output = @import("effect_output.zig");

const Engine = engine.Engine;
pub const default_state_dir = "/nix/var/nix";

pub fn stateDir(init: std.process.Init) []const u8 {
    const value = init.environ_map.get("NIX_STATE_DIR") orelse return default_state_dir;
    return if (value.len == 0) default_state_dir else value;
}

/// Resolve the worker-thread count: an explicit `--workers`, else
/// `min(12, cpu_count)` (1 when single-threaded).
/// The default cap limits speculative and idle-thread overhead after demand
/// parallelism saturates. `--workers` remains available for explicit tuning.
pub fn workerCount(options: *const args.Options) !u8 {
    return options.workers orelse if (builtin.single_threaded)
        1
    else
        @intCast(@min(@as(u32, 12), @as(u32, @intCast(try std.Thread.getCpuCount()))));
}

/// Resolve the process capabilities that must be present when the engine's
/// long-lived services are constructed. Remaining language/store policy is
/// applied by `Session.configure` after nix.conf has been folded. `options`
/// is null only for engines with no parsed command line (completions).
pub fn engineConfig(
    init: std.process.Init,
    worker_count: u8,
    memory_backing: ?*hugetlb.Policy,
    options: ?*const args.Options,
) engine.EngineConfig {
    const compile_cache: engine.CompileCacheConfig = if (options) |o|
        (if (o.no_compile_cache)
            .off
        else if (o.compile_cache_dir) |dir|
            .{ .dir = dir }
        else
            .auto)
    else
        .auto;
    return .{
        .worker_count = worker_count,
        .io = init.io,
        .environment = init.environ_map,
        .memory_backing = memory_backing,
        .compile_cache = compile_cache,
    };
}

pub const Terminal = struct {
    use_color: bool,
    color_depth: presentation.ColorDepth,
    log_progress: bool,
    output: *effect_output.StderrSink,

    pub fn progressEnabled(self: Terminal) bool {
        return self.log_progress;
    }

    fn deinit(self: Terminal, allocator: std.mem.Allocator) void {
        self.output.destroy(allocator);
    }
};

/// Owns the composition lifetime of an evaluator and its CLI-facing output.
///
/// `Engine` borrows the callback context stored in `terminal`, so teardown must
/// quiesce the evaluator before releasing that context. Keeping both actions
/// behind one defer prevents command call sites from accidentally reversing
/// their order.
pub const Session = struct {
    engine: *Engine,
    terminal: ?Terminal = null,

    pub const Teardown = enum {
        full,
        /// The process exits immediately after the command. Drain durable
        /// chunk-cache writes, but let the kernel reclaim the evaluator and its
        /// still-borrowed output together.
        fast_exit,
    };

    pub fn init(ev: *Engine) Session {
        return .{ .engine = ev };
    }

    pub fn configure(
        self: *Session,
        process_init: std.process.Init,
        options: *const args.Options,
        settings: *nix_conf.Settings,
    ) !Terminal {
        std.debug.assert(self.terminal == null);
        const terminal = try configureEngine(self.engine, process_init, options, settings);
        self.terminal = terminal;
        return terminal;
    }

    pub fn deinit(self: *Session, teardown: Teardown) void {
        if (teardown == .fast_exit) {
            // Durable chunk-cache state must survive the fast exit: queued
            // unit writes and the import manifest the next run preloads.
            self.engine.writeChunkCacheManifest();
            self.engine.flushChunkCacheWrites();
            // Deliberately retain `terminal`: Engine still borrows its sink and
            // the process-exit contract lets the kernel reclaim both together.
            return;
        }
        const allocator = self.engine.hostAllocator();
        self.engine.deinit();
        if (self.terminal) |terminal| terminal.deinit(allocator);
        self.terminal = null;
    }
};

/// Resolve the process-owned memory-backing policy that must be decided BEFORE
/// `Engine.init` maps the heap (the flat object store picks its mapping
/// at init): `--hugetlb` (`cli_mode`, null for subcommands without the shared
/// parser), defaulting to `auto`.
/// Deliberately NOT a nix.conf setting: config loads in `Session.configure`,
/// after the heap already exists, so a config-sourced value could only half-apply.
/// Call before `Engine.init` in every eval-producing subcommand.
pub fn applyMemoryBacking(
    process: @import("process_context.zig").ProcessContext,
    cli_mode: ?hugetlb.Mode,
) ?*hugetlb.Policy {
    const policy = process.memory_backing orelse return null;
    policy.setMode(cli_mode orelse .auto);
    return policy;
}

/// Apply already-resolved settings and CLI policy to an Engine, then derive
/// terminal presentation. This phase performs no configuration discovery and
/// does not construct a hidden evaluator.
fn configureEngine(
    ev: *Engine,
    init: std.process.Init,
    options: *const args.Options,
    settings: *nix_conf.Settings,
) !Terminal {
    // Lazy shells only matter for lazy-XML rendering; elsewhere the wrap is
    // pure thunk-allocation overhead (see `vm.lazy_shells_visible`).
    ev.setLazyShellsVisible(options.output == .xml);
    ev.setParallelismToggles(options.disable_spec_thunks, options.disable_fanout);
    ev.configureMemory(options.gc_budget, options.mem_report, options.gc_report);
    // Experimental features and the concurrent-fetch cap both come from
    // `nix.conf` (best-effort: unreadable config just uses defaults), so load it
    // once. The CLI-parsed feature set is the starting point; unless the CLI
    // *replaced* it with `--experimental-features`, the config's
    // `experimental-features` is the base and any `--extra-experimental-features`
    // additions are layered on top (Nix precedence). Config-sourced features
    // that `fix` doesn't recognize are silently skipped, as in Nix.
    var features = options.experimental_features;
    var http_conn: u64 = 25; // Nix default; 0 = unlimited.
    ev.setTraceVerbose(boolSetting(settings, "trace-verbose", false));
    if (!options.experimental_features_reset) {
        if (settings.get("experimental-features")) |list|
            args.mergeConfigFeatures(&features, list);
    }
    http_conn = settings.getUint("http-connections") orelse 25;

    var policy = ev.languagePolicy();
    policy.applyFeatureSets(features, options.deprecated_features);
    // `--option max-call-depth N` (Nix's call-recursion bound). Clamp to u32.
    if (settings.getUint("max-call-depth")) |n|
        policy.max_call_depth = @intCast(@min(n, @as(u64, std.math.maxInt(u32))));
    ev.configureLanguage(policy);
    try ev.setFetchConnections(@intCast(@min(http_conn, @as(u64, std.math.maxInt(u32)))));
    if (settings.getUint("download-attempts")) |n|
        ev.setDownloadAttempts(@intCast(@min(n, @as(u64, std.math.maxInt(u32)))));
    ev.setTarballTtl(@intCast(@min(settings.getUint("tarball-ttl") orelse 3600, @as(u64, std.math.maxInt(u32)))));
    if (settings.getUint("connect-timeout")) |n|
        ev.setFetchConnectTimeout(@intCast(@min(n, @as(u64, std.math.maxInt(u32)))));
    ev.setStalledDownloadTimeout(@intCast(@min(settings.getUint("stalled-download-timeout") orelse 300, @as(u64, std.math.maxInt(u32)))));
    ev.setDownloadSpeed(settings.getUint("download-speed") orelse 0);
    // The process environment has higher precedence than nix.conf for the CA
    // bundle, matching Nix.
    if (init.environ_map.get("NIX_SSL_CERT_FILE") == null and init.environ_map.get("SSL_CERT_FILE") == null)
        if (settings.get("ssl-cert-file")) |path| if (path.len != 0) try ev.setSslCertFile(path);
    const registry = settings.get("flake-registry") orelse "https://channels.nixos.org/flake-registry.json";
    try ev.setFlakeRegistryUrl(if (registry.len != 0) registry else null);
    // `access-tokens` from nix.conf (incl. `--option access-tokens ...`):
    // authenticate fetches to private GitHub/GitLab/… hosts.
    if (settings.get("access-tokens")) |tokens| try ev.setAccessTokens(tokens);
    try applyNetrc(ev, init, settings);
    // The store directory follows `store-dir` from nix.conf, with `NIX_STORE_DIR`
    // taking precedence (as Nix does for this setting). Defaults to `/nix/store`.
    if (init.environ_map.get("NIX_STORE_DIR") orelse settings.get("store-dir")) |dir| {
        try ev.setStoreDir(dir);
    } else if (settings.get("store")) |uri| {
        if (uri.len != 0 and !std.mem.eql(u8, uri, "daemon") and std.mem.indexOf(u8, uri, "://") == null) {
            try ev.setStoreDir(uri);
        }
    }
    // A nonstandard state directory moves the default daemon socket for both
    // Nix and Lix. An explicit socket path still wins.
    if (init.environ_map.get("NIX_DAEMON_SOCKET_PATH")) |sock| {
        if (sock.len != 0) {
            const uri = try std.fmt.allocPrint(ev.hostAllocator(), "unix://{s}", .{sock});
            defer ev.hostAllocator().free(uri);
            try ev.setDaemonSocket(uri);
        }
    } else if (init.environ_map.get("NIX_STATE_DIR") != null) {
        const socket = try std.fs.path.join(ev.hostAllocator(), &.{ stateDir(init), "daemon-socket", "socket" });
        defer ev.hostAllocator().free(socket);
        const uri = try std.fmt.allocPrint(ev.hostAllocator(), "unix://{s}", .{socket});
        defer ev.hostAllocator().free(uri);
        try ev.setDaemonSocket(uri);
    }
    // The store URI (`store` from nix.conf / `NIX_REMOTE` / `--store`)
    // selects the daemon transport and wins over NIX_DAEMON_SOCKET_PATH.
    // Validate it here so unsupported native backends get a useful diagnostic
    // instead of being flattened into StoreUnavailable by the connection pool.
    if (settings.get("store")) |uri| {
        if (uri.len != 0) {
            store.daemon.validateStoreUri(uri) catch |err| {
                const use_color = presentation.colorDepth(options.color, init.io, init.environ_map).enabled();
                switch (err) {
                    error.NativeLocalStoreUnsupported => render.messageError(init.io, use_color, "local, auto, and chroot stores need fix's native local-store backend, which is not implemented yet", .{}),
                    error.UnsupportedSshStoreSetting => render.messageError(init.io, use_color, "this ssh-ng store setting is not implemented; supported settings are port, ssh-key, and compress", .{}),
                    error.UnsupportedLixRpcProtocol => render.messageError(init.io, use_color, "this Lix endpoint only offers lix-xp-1, which fix does not implement yet", .{}),
                    error.UnsupportedDaemonProtocol => render.messageError(init.io, use_color, "the store URI requests an unsupported daemon protocol", .{}),
                    else => render.messageError(init.io, use_color, "invalid or unsupported store URI: {s}", .{uri}),
                }
                return error.ConfigError;
            };
            if (std.fs.path.isAbsolute(uri)) {
                // Older Nix/Lix environments also spell the standard daemon
                // endpoint as a bare absolute `.../daemon-socket/socket` URI.
                const tagged = try std.fmt.allocPrint(ev.hostAllocator(), "unix://{s}", .{uri});
                defer ev.hostAllocator().free(tagged);
                try ev.setDaemonSocket(tagged);
            } else {
                try ev.setDaemonSocket(uri);
            }
        }
    }
    try applyDaemonSettings(ev, options, settings);
    try ev.setBasePathFromCurrentPath(init.io);
    try applyNixPath(ev, init, options);

    const color_depth = presentation.colorDepth(options.color, init.io, init.environ_map);
    const use_color = color_depth.enabled();
    const progress = presentation.progressPolicy(options.progress);
    if (use_color) std.Io.File.stderr().enableAnsiEscapeCodes(init.io) catch {};
    const output = try effect_output.StderrSink.create(
        ev.hostAllocator(),
        init.io,
        presentation.isStderrInteractive(init.io, init.environ_map),
    );
    ev.setEffectSink(output.effectSink());
    return .{
        .use_color = use_color,
        .color_depth = color_depth,
        .log_progress = progress.log,
        .output = output,
    };
}

/// Send per-connection daemon settings via `set_options` when the store
/// connects. Both fixed fields and the overrides map use only user config,
/// `$NIX_CONFIG`, flake `nixConfig`, and CLI settings. System nix.conf values
/// are not forwarded: the daemon has already loaded its own system
/// configuration. `set_options` is only emitted when the store
/// actually connects (build/instantiate/run/shell), never for plain `eval`.
fn applyDaemonSettings(ev: *Engine, options: *const args.Options, settings: *nix_conf.Settings) !void {
    const allocator = ev.hostAllocator();
    var overrides: std.ArrayListUnmanaged(store.daemon.Setting) = .empty;
    defer overrides.deinit(allocator);
    var it = settings.daemon.iterator();
    while (it.next()) |e| {
        try overrides.append(allocator, .{ .name = e.key_ptr.*, .value = e.value_ptr.* });
    }

    // setDaemonBuildSettings dupes the overrides into owned storage, so this
    // borrowed slice need only live across the call.
    try ev.setDaemonBuildSettings(.{
        .keep_failed = daemonBoolSetting(settings, "keep-failed", false),
        .keep_going = daemonBoolSetting(settings, "keep-going", false),
        .fallback = daemonBoolSetting(settings, "fallback", false),
        .verbosity = @min(7, options.verbose),
        .suppress_build_output = options.no_build_output,
        .max_build_jobs = daemonJobsSetting(settings, "max-jobs", 1),
        .max_silent_time = daemonGetUint(settings, "max-silent-time") orelse 0,
        .build_cores = daemonGetUint(settings, "cores") orelse 0,
        .use_substitutes = daemonBoolSetting(settings, "substitute", true),
        .overrides = overrides.items,
    });
}

/// Load the `netrc-file` (default `$NIX_CONF_DIR/netrc`, matching Nix) and hand
/// its credentials to the fetcher for HTTP basic-auth on plain downloads.
/// Best-effort: a missing/unreadable file just means no netrc auth.
fn applyNetrc(ev: *Engine, init: std.process.Init, settings: *nix_conf.Settings) !void {
    const allocator = ev.hostAllocator();
    const path: []u8 = if (settings.get("netrc-file")) |p|
        try allocator.dupe(u8, p)
    else blk: {
        const dir = init.environ_map.get("NIX_CONF_DIR") orelse "/etc/nix";
        break :blk try std.fs.path.join(allocator, &.{ dir, "netrc" });
    };
    defer allocator.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1 << 20)) catch return;
    defer allocator.free(data);
    try ev.setNetrc(data);
}

/// Read a boolean `nix.conf` setting (`true`/`1` = true, any other value =
/// false), falling back to `default` when unset.
fn boolSetting(settings: *nix_conf.Settings, key: []const u8, default: bool) bool {
    const v = settings.get(key) orelse return default;
    const t = std.mem.trim(u8, v, " \t");
    return std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "1");
}

fn daemonGetUint(settings: *nix_conf.Settings, key: []const u8) ?u64 {
    const v = settings.daemon.get(key) orelse return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10) catch null;
}

fn daemonBoolSetting(settings: *nix_conf.Settings, key: []const u8, default: bool) bool {
    const v = settings.daemon.get(key) orelse return default;
    const t = std.mem.trim(u8, v, " \t");
    return std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "1");
}

fn daemonJobsSetting(settings: *nix_conf.Settings, key: []const u8, default: u64) u64 {
    const v = settings.daemon.get(key) orelse return default;
    const t = std.mem.trim(u8, v, " \t");
    if (std.mem.eql(u8, t, "auto")) return @intCast(std.Thread.getCpuCount() catch 1);
    return std.fmt.parseInt(u64, t, 10) catch default;
}

/// Build the evaluator's search path from `-I`/`--include` entries followed by
/// `$NIX_PATH`. Command-line entries come first so they take precedence, as in
/// Nix. With neither present, fall back to Nix's default search path — the
/// user and root channel profiles — so `<nixpkgs>` resolves on a machine
/// configured purely through `nix-channel`.
fn applyNixPath(ev: *Engine, init: std.process.Init, options: *const args.Options) !void {
    const allocator = ev.hostAllocator();
    const env_path = init.environ_map.get("NIX_PATH");
    if (options.include.items.len == 0 and env_path == null) {
        if (init.environ_map.get("HOME")) |home| {
            const fallback = try std.fmt.allocPrint(
                allocator,
                "{s}/.nix-defexpr/channels:nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixpkgs:/nix/var/nix/profiles/per-user/root/channels",
                .{home},
            );
            defer allocator.free(fallback);
            try ev.setNixPath(fallback);
        }
        return;
    }
    if (options.include.items.len == 0) {
        if (env_path) |nix_path| try ev.setNixPath(nix_path);
        return;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    for (options.include.items) |entry| {
        if (buf.items.len != 0) try buf.append(allocator, ':');
        try buf.appendSlice(allocator, entry);
    }
    if (env_path) |nix_path| {
        if (nix_path.len != 0) {
            try buf.append(allocator, ':');
            try buf.appendSlice(allocator, nix_path);
        }
    }
    try ev.setNixPath(buf.items);
}

test "Session cleans up an Engine when configuration does not complete" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0, .io = std.testing.io });
    var session = Session.init(&ev);
    session.deinit(.full);
}

test "Session retains effect output through Engine teardown" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0, .io = std.testing.io });
    const output = try effect_output.StderrSink.create(std.testing.allocator, std.testing.io, false);
    ev.setEffectSink(output.effectSink());

    var session = Session.init(&ev);
    session.terminal = .{
        .use_color = false,
        .color_depth = .none,
        .log_progress = false,
        .output = output,
    };
    session.deinit(.full);
}

test "Session fast exit retains output borrowed by the live Engine" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0, .io = std.testing.io });
    const output = try effect_output.StderrSink.create(std.testing.allocator, std.testing.io, false);
    ev.setEffectSink(output.effectSink());

    var session = Session.init(&ev);
    session.terminal = .{
        .use_color = false,
        .color_depth = .none,
        .log_progress = false,
        .output = output,
    };
    session.deinit(.fast_exit);
    try std.testing.expect(session.terminal != null);

    // Tests cannot exit the process, so finish the retained ownership normally.
    session.deinit(.full);
}
