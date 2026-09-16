//! User-facing `fix` subcommands.

const thunks_log_enabled = @import("expr").vm.thunks_log_enabled;
const vm_trace_enabled = @import("expr").vm.trace_log.enabled;
const command_meta = @import("../command_meta.zig");
const ProcessContext = @import("../process_context.zig").ProcessContext;
const std = @import("std");

pub const Runner = *const fn (ProcessContext, std.process.Init, *std.process.Args.Iterator) anyerror!u8;

pub const eval = @import("eval.zig");
pub const daemon = @import("daemon.zig");
pub const flake = @import("flake.zig");
pub const completions = @import("completions.zig");
pub const parse = @import("parse.zig");
pub const print_dev_env = @import("print_dev_env.zig");
pub const instantiate = @import("instantiate.zig");
pub const build = @import("build.zig");
pub const run = @import("run.zig");
pub const shell = @import("shell.zig");
pub const @"switch" = @import("switch.zig");
pub const repl = @import("repl.zig");
pub const disasm = @import("disasm.zig");
pub const trace = if (vm_trace_enabled) @import("trace.zig") else struct {};
pub const thunks = if (thunks_log_enabled) @import("thunks.zig") else struct {};

/// Bind canonical command identities to their implementations. Keeping this
/// at the commands boundary leaves the process entry point registry-agnostic.
pub fn runner(comptime kind: command_meta.Kind) Runner {
    return switch (kind) {
        .build => build.run,
        .completions => completions.run,
        .daemon => daemon.run,
        .disasm => disasm.run,
        .eval => eval.run,
        .flake => flake.run,
        .instantiate => instantiate.run,
        .parse => parse.run,
        .print_dev_env => print_dev_env.run,
        .repl => repl.run,
        .run => run.run,
        .shell => shell.run,
        .@"switch" => @"switch".run,
        .thunks => thunks.run,
        .trace => trace.run,
    };
}
