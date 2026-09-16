//! User-facing top-level command metadata, kept in display/completion order.

pub const Kind = enum {
    build,
    completions,
    daemon,
    disasm,
    eval,
    flake,
    instantiate,
    parse,
    print_dev_env,
    repl,
    run,
    shell,
    @"switch",
    thunks,
    trace,
};

pub const Command = struct {
    kind: Kind,
    name: []const u8,
    summary: []const u8,
    args_cmd: ?Kind,
};

/// Build-time availability policy shared by dispatch, help, and completion.
pub fn enabled(kind: Kind) bool {
    return switch (kind) {
        .thunks => @import("expr").vm.thunks_log_enabled,
        .trace => @import("expr").vm.trace_log.enabled,
        else => true,
    };
}

pub const table = [_]Command{
    .{ .kind = .build, .name = "build", .summary = "evaluate to a derivation, build its outputs, and link ./result", .args_cmd = .build },
    .{ .kind = .completions, .name = "completions", .summary = "generate shell completions for bash, zsh, or fish", .args_cmd = null },
    .{ .kind = .daemon, .name = "daemon", .summary = "run a Nix-compatible worker-protocol daemon server", .args_cmd = null },
    .{ .kind = .disasm, .name = "disasm", .summary = "disassemble compiled bytecode for an expression", .args_cmd = .disasm },
    .{ .kind = .eval, .name = "eval", .summary = "evaluate an expression, file, or flake output and print the value", .args_cmd = .eval },
    .{ .kind = .flake, .name = "flake", .summary = "inspect and manage flakes (metadata, show, check, update, lock)", .args_cmd = null },
    .{ .kind = .instantiate, .name = "instantiate", .summary = "evaluate to a derivation and add its .drv closure to the store", .args_cmd = .instantiate },
    .{ .kind = .parse, .name = "parse", .summary = "parse an expression and print its AST as JSON", .args_cmd = .parse },
    .{ .kind = .print_dev_env, .name = "print-dev-env", .summary = "print a derivation's build environment as a bash script (direnv `use fix`)", .args_cmd = .print_dev_env },
    .{ .kind = .repl, .name = "repl", .summary = "start an interactive read-eval-print loop", .args_cmd = .repl },
    .{ .kind = .run, .name = "run", .summary = "build a derivation and run a program from its output", .args_cmd = .run },
    .{ .kind = .shell, .name = "shell", .summary = "build a derivation and open a shell with its bin/ on PATH", .args_cmd = .shell },
    .{ .kind = .@"switch", .name = "switch", .summary = "build and activate a NixOS/nix-darwin/home-manager configuration", .args_cmd = .@"switch" },
    .{ .kind = .thunks, .name = "thunks", .summary = "diff thunks-logs to find divergent resolutions", .args_cmd = null },
    .{ .kind = .trace, .name = "trace", .summary = "work with binary VM trace files", .args_cmd = null },
};

pub fn get(comptime kind: Kind) Command {
    inline for (table) |command| {
        if (command.kind == kind) return command;
    }
    unreachable;
}

test "command table is alphabetized" {
    const std = @import("std");
    for (table[1..], table[0 .. table.len - 1]) |command, previous| {
        try std.testing.expect(std.mem.lessThan(u8, previous.name, command.name));
    }
}
