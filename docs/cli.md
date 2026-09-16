# CLI

*The command surface and the tools for inspecting evaluation.*

The `cli` module owns command parsing, presentation, progress, and the shared
evaluation-to-realization workflow. Commands use the durable `expr`, `runtime`,
`syntax`, and `store` modules directly; `src/main.zig` only composes the process
and dispatches a required subcommand. `src/cli/args.zig` is the source of truth
for the common option grammar.

## Invocation

```
fix <command> [options]
```

A subcommand is **required** (there is no default command). POSIX conventions: `-h`/`--help` prints help to **stdout** and exits `0`; a missing/unknown command or a bad argument prints usage to **stderr** and exits nonzero (`2`). `fix <command> -h` prints that command's scoped help. `fix --version` prints the release version and the emulated Nix language baseline (the same value `builtins.nixVersion` reports).

## Subcommands

Each is a self-contained tool with its own `-h`. `eval`/`repl` evaluate expressions; `instantiate`/`build`/`run`/`shell`/`switch` also realize derivations through the nix-daemon. `parse`, `disasm`, and the conditional trace commands expose intermediate representations; `completions` generates shell integration.

| Subcommand | Purpose | Link |
|---|---|---|
| `build` | evaluate to a derivation, build its outputs via the nix-daemon, and link `./result` | [derivation/model.md](derivation/model.md) |
| `completions bash|zsh|fish` | generate a shell completion script on stdout | — |
| `disasm` | decompile bytecode per-chunk with source-span, constant, and local/upvalue-name annotation | [compiler/pipeline.md](compiler/pipeline.md), [vm/dispatch.md](vm/dispatch.md) |
| `eval` | evaluate mixed expression/file/flake inputs and render each value | — |
| `flake metadata\|show\|check\|update\|lock [flakeref]` | inspect and manage a flake (see below) | — |
| `gc` | delete store paths unreachable from the GC root set (see below) | — |
| `instantiate` | evaluate to a derivation and add its `.drv` closure to the store (à la `nix-instantiate`) | [derivation/model.md](derivation/model.md) |
| `parse` | parse and statically validate an expression, then print the `nix-instantiate --parse` JSON AST | [syntax/parsing.md](syntax/parsing.md) |
| `print-dev-env` | evaluate a derivation and emit its build environment as a Bash program (used by `use fix`) | — |
| `repl` | interactive read-eval loop | — |
| `run` | build a derivation and run a program from its output | — |
| `shell` | build a derivation and open a shell with its `bin/` on `PATH` (`-p NAMES...` pulls packages from `<nixpkgs>`) | — |
| `switch` | build and activate a NixOS, nix-darwin, or home-manager configuration | — |
| `trace dump PATH` / `trace diff A B` | read binary VM-execution trace files: `dump` pretty-prints one as text; `diff` walks two in lockstep to the first divergent event (`-Dvm-trace` builds only) | [vm/dispatch.md](vm/dispatch.md) |
| `thunks diff A B` | diff two thunk-resolution logs → first divergence by source location (`-Dthunks-log` builds only) | below |

## Store garbage collection

`fix gc [--store-dir DIR] [--gcroots DIR] [--dry-run]` reclaims top-level store
entries unreachable from the GC root set. Roots are the symlinks under the
gcroots directory (default `<store-dir>/gcroots`, or `$NIX_STATE_DIR/gcroots`
for `/nix/store`); reachability follows each entry's references, obtained by
scanning its file contents for store paths (a `.drv` therefore keeps its input
derivations, sources, and outputs). `--dry-run` lists what would be deleted
without touching the store. A non-entry file such as the daemon's `socket` is
never considered.

The `fix daemon` server records `add_temp_root` (kept in memory) and
`add_indirect_root` (as `gcroots/auto/<hash>` links) and shares the same
collector. `--gc` runs one collection and exits; `--gc-interval SECS` runs one
every N seconds while serving, but only when no connection is mid-write.

## The repl

`fix repl` (`src/cli/commands/repl.zig` + `src/cli/repl/`) has two input modes, decided once at startup:

- **Interactive** — stdin *and* stdout are a tty. The normal REPL is an ordinary inline prompt and leaves terminal scrollback alone. `:vm` explicitly enters an alternate-screen VM workspace containing the explorer, a bounded transcript, and the same editor. In explorer mode, `i` enters an expression and `:` enters a command; Escape returns from an empty prompt to the explorer, and `q`/Escape leaves the workspace. Anything evaluated inside it is replayed into normal scrollback after the alternate screen is restored. The editor keeps emacs-style editing (C-a/C-e/C-k/C-u/C-w/C-y + kill ring, M-b/M-f word motion), persistent history (`$XDG_STATE_HOME/fix/repl-history`, multiline entries round-trip) with C-r incremental search, Tab completion, bracketed paste, SIGWINCH-aware rendering, and C-z suspend/resume. Raw mode is restored on **every** exit path — orderly return, panic (SIGABRT), fatal signal — via a saved-termios global + chained signal handlers (`repl/term.zig`). `--no-tui` retains that editor, color, history, completion, and key handling while rendering `:debug` and `:vm` inline instead of opening an alternate-screen workspace.
- **Streaming** — when either end is not a tty, the REPL uses a plain read-a-line loop with zero escape sequences. Lines still accumulate until they parse as a complete expression, so multiline scripts pipe fine.

**Smart-enter.** Enter submits only when the input parses as a complete expression (the real parser decides: an error at EOF means "more is coming"); otherwise it opens a continuation line (`...>` prompt). Alt-Enter submits as-is; C-o inserts a newline. Multiline history entries recall as multiline; Up/Down move within lines before browsing history.

**Completion (Tab).** Readline model: common prefix first, candidate menu on the second Tab; further Tabs cycle forward and Shift-Tab cycles backward through that stable candidate set. Sources by context: `:` commands; scope bindings + keywords + globally-visible builtins for bare identifiers; attribute paths (`foo.ba<TAB>`) resolved through **already-forced** values only — the completer never starts evaluation; file paths inside string/path literals.

**Scope.** `name = expr` binds; the last printed value is `it`; `:l PATH` merges a file's attrset into scope (auto-calling a top-level function with `{}`); `:r` reloads. Inputs compile inside an ambient scope attrset (the `scopedImport` mechanism), so bound values are *shared*, never re-evaluated.

**GC.** A collection runs between inputs (`Engine.collectNow`: the standard STW barrier driven from outside an evaluation), so session memory tracks the live bindings rather than accreting. Repl-held values are precise GC roots (`Engine.gcSetExternalRoots` → `collection.extra_roots`). `:gc` collects on demand and reports reserved bytes.

**Commands** (`:?` shows this table in-repl): `:?`/`:help`, `:q`/`:quit`/`:exit`, `:l`/`:load PATH`, `:r`/`:reload`, `:t`/`:type EXPR`, `:p`/`:print EXPR` (deep-force), `:i`/`:inspect EXPR` (kind, thunk state + backing chunk, closure chunk/arity), `:debug`/`:d EXPR` (pause before forcing an expression), `:vm [COMMAND | EXPR]`, `:env`, `:gc`.

**`:vm` — inspect the VM.** `:vm EXPR` evaluates and focuses the resulting
chunk; plain `:vm` reopens that focus, and `:vm chunk ID` selects a registry
chunk directly. The full-screen explorer exposes source, bytecode, chunk tables,
references, and heap objects. Its trees are lazy and range-based, so large
registries and heaps remain navigable.

The code panel follows chunk and heap references and can toggle a source
breakpoint for the selected instruction. Heap views expose semantic fields and
further references; breakpoint requests are shared with debugger sessions.

Explorer indexes and censuses run off the evaluation path. Large stores are
presented as expandable ranges, and the transcript is bounded, so inspecting a
large evaluation does not require materializing every object or line at once.

Inline mode provides the same model through bounded queries: `:vm ls`,
`:vm chunks`, and `:vm find` browse bytecode; `:vm chunk`, `:vm spans`,
`:vm heap`, `:vm store`, `:vm record`, `:vm object`, and `:vm refs` inspect
specific records and relationships. `:vm break-at`, `:vm clear-at`,
`:vm breakpoints`, and `:vm delete` manage instruction and source breakpoints.
Listings default to 40 rows and accept at most 1,000.

The explorer owns its layout and interaction policy; the shared terminal layer
owns alternate-screen lifecycle, clipping, and color rendering.

## The debugger

`fix eval --debugger` (and `fix repl --debugger`) pauses evaluation in a debugger — Nix's `--debugger` model — at three points:

- **`builtins.break x`** — a break in the source. `break` is otherwise the identity on `x`, so it can be dropped anywhere: `let y = builtins.break (f a); in ...`.
- **a source-line breakpoint** — `break FILE:LINE` from the console. See [Source-line breakpoints](#source-line-breakpoints).
- **an evaluation error** — an uncaught `throw`, `abort`, or failed `assert` pauses at the origin (call frames still live) *before* the error unwinds and prints. Errors caught by `builtins.tryEval` do **not** pause.

`--debugger` forces `--workers=1` and disables speculation and fan-out so the pause point is deterministic — a single demand fiber, no helper racing ahead of the break. An interactive REPL uses a full-screen debugger with live stack, syntax-highlighted source, exact-span focus, disassembly, and lazy locals/output panes. Every stop carries an increasing pause number so a loop that returns to the same span still visibly advances. In its source view, `b` toggles a breakpoint on the selected frame line (`B` opens the explicit `break FILE:LINE` prompt), and breakpoint lines remain marked in the gutter. It owns an alternate screen when entered from the ordinary inline prompt, but borrows the already-active screen and raw mode when entered from `:vm`; the VM explorer redraws as soon as evaluation resumes. `fix eval --debugger`, a non-TTY REPL, and `fix repl --no-tui` retain the line-oriented console, which reads stdin and writes stderr so redirected stdout receives only the final value and automation sees no escape sequences.

The REPL also offers `:debug EXPR` / `:d EXPR` without requiring a persistent `--debugger` session. It installs the debugger for that evaluation, gates speculative and fan-out submissions through an atomic scheduler switch, and patches a one-shot entry stop into a private execution overlay before it runs. The expression's registered bytecode remains unchanged, so the first pause and every later step refer to user source rather than a synthetic wrapper. Continuing evaluates, binds, and prints the result normally; afterward the UI and scheduler gate are detached, so later REPL evaluations regain their configured parallel behavior.

**Commands and keys.** Both frontends use the same command parser. A bare line is a **Nix expression** evaluated in the pause's scope; a command word alone runs the command (so `n + base` evaluates but `n` steps), and a leading `:` forces command interpretation. In the TUI, `s`/`n`/`f`/`c` are direct step controls, `j`/`k` or the arrow keys select a frame, `v` or Tab toggles source/disassembly, `b` toggles the selected line's breakpoint (`B` opens a breakpoint prompt), `i` opens an expression prompt, and `:` opens the shared command prompt.

| command | effect |
|---|---|
| `<expr>` | evaluate an expression in the breakpoint's scope (see below) |
| `bt` / `backtrace` | the call stack, innermost first, with `file:line:col`, chunk name, and `#chunk` id |
| `l` / `locals` | in-scope named locals and upvalues, grouped per frame |
| `:frame [DEPTH]` | one frame's source, non-forcing locals/upvalues, VM operand stack, and annotated bytecode (`#0` is innermost) |
| `v` / `value` | the value passed to `builtins.break` (or the error subject) |
| `:vm QUERY` | the same bounded chunk, heap-store, object, span, reference, and breakpoint queries as REPL `:vm` |
| `break FILE:LINE` | set a source-line breakpoint |
| `breakpoints` / `delete N` | list / remove breakpoints |
| `:gc` | run a full collection at the pause and refresh debugger heap views |
| `n` / `next` | step to the next line, over calls |
| `s` / `step` | step to the next line, into calls |
| `finish` | run until the current frame returns |
| `c` / `continue` | resume evaluation |
| `q` / `quit` | abort evaluation |
| `help` | command list |

Frames show names when chunk-name capture is on (`--debugger` and every REPL session enable it), so a backtrace reads like `pkgs/hello.nix:12:3 hello (chunk #42)`. Console expressions run on a fresh nested VM sharing the registry, heap, and intern table, so inspecting a value never disturbs the pause point.

**Source, bytecode & color.** The TUI keeps the selected frame's source centered on its current span and can switch that pane to annotated bytecode without leaving the pause. Both frontends show locals and operand-stack values without forcing thunks; only an explicit expression or `value` command renders and therefore may force a value. The console's automatic stop banner prints the current line with context and a caret, while `:frame DEPTH` emits the TUI's complete frame document into scrollback. Source comes from the FileCache (imported files) or the stashed entry text. Rendered values use the normal evaluator palette whenever the terminal takes color; semantic TUI roles are quantized through the shared terminal-color model.

**Scope-accurate evaluation.** A console expression resolves the breakpoint's lexical bindings — `let` bindings, lambda params, captured upvalues, and `with`-scopes — not just globals. The compiler records a slot→name table per chunk (gated on the same capture flag, so normal builds pay nothing), and the console reconstructs an ambient scope from the frame stack: named locals and upvalues (inner frames shadow outer), plus each in-effect `with` attrset merged at lowest precedence (a `with` subject is a nameless local slot or a `"\x00with"` upvalue; lexical bindings shadow it, inner `with` shadows outer), plus `it` = the break value. Because a break often lands in a small argument thunk whose own frame has no locals, the scope merges *all* live frames, so `base`, a param `n`, or an attr `hello` from `with pkgs;` all resolve.

### Source-line breakpoints

`break FILE:LINE` pauses whenever execution reaches that line — set it during any pause (drop a `builtins.break` near the entry to get an initial one). The request may name a file which has not been imported yet; it is listed as pending, resolves to the nearest executable line when that file finishes its first compilation, and patches later deferred bodies too. It's implemented by **patching a private code overlay**, not by a per-instruction check: `BreakpointTable` copies a chunk's canonical code on first use, then overwrites the selected opcode byte with a dedicated `breakpoint` opcode that pauses the debugger and chains to the saved original opcode (its operands are untouched). The registry chunk stays immutable, and the hot dispatch loop pays nothing until a frame selects a patched overlay. `delete N` restores the overlay bytes. Because bodies compile lazily (imports, deferred attrs register mid-evaluation), a per-registry hook applies pending breakpoints to each newly registered chunk.

The compiler emits source-map entries for expression nodes; a requested line
resolves to the nearest line carrying code and reports when that differs. A
single source line can compile into several chunks, so one request may resolve
to multiple sites. Persistent `fix eval --debugger` and
`fix repl --debugger` sessions use one worker. A transient `:debug` evaluation
in an ordinary REPL enables the scheduler's debug-serial gate instead.

### Stepping

`next`, `step`, and `finish` reuse the breakpoint mechanism: each **arms temporary overlay patches** and resumes; the next pause is the landing point. `next` patches every distinct source-span site in the current chunk plus the caller's return point and stops at the current frame depth or shallower (so it doesn't stop inside a deeper recursion). `step` additionally patches the entry of every chunk the current one may call or force, and follows chunks compiled after the command is armed (imports and deferred bodies), stopping at any depth. `finish` patches only the caller's return point. `BreakpointTable.hit` applies the depth guard: a permanent breakpoint always pauses, a step temp only at the target depth; the console clears the step's temps at the next pause.

One honest caveat: this is a **lazy** language, so stepping follows *demand* order, not source order. Stepping "over" a line whose value is a thunk lands wherever that thunk is actually forced — often a different binding or file — and a value already forced (memoised) is skipped. `step` into a call typically lands in the argument thunk first (Nix forces arguments on demand). Stepping is most intuitive as "step into this call and see where evaluation goes next," less so as classic line-by-line imperative stepping. Results are always preserved — a step patch chains to the original opcode. Imports execute in fresh nested VMs, but those VMs retain a debugger-parent link, so `bt`, `next`, and `finish` see one logical stack across the import boundary.

**Source locations.** The debugger maps each frame to its narrowest source span,
including callers suspended just after a call, so backtraces retain useful source
locations across call boundaries.

**Architecture.** The expression engine exposes a debugger view over a paused
VM and keeps registry bytecode immutable by applying breakpoints through a
private overlay. The CLI supplies either a console or the integrated VM screen
through that view; both use the same command language.

## Key flags

The data-driven `Spec` table in `src/cli/args.zig` is the source of truth: it drives parsing *and* per-command `--help` visibility (each spec lists the subcommands it applies to). Defaults shown; `[=X]` means the value is optional.

### Source input (`eval`/`parse`/`instantiate`/`build`/`run`/`shell`/`disasm`/`switch`)

| Flag | Meaning |
|---|---|
| `FILEISH` (positional) | append a legacy fileish input. `eval`, `parse`, `instantiate`, `build`, `run`, and `disasm` default to `./default.nix`; `shell` requires a source or `-p`; `switch` has a target-specific default. |
| `-E, --expr EXPR` | append expression text; repeatable |
| `-f, --file FILEISH` | append a fileish input (same as a bare argument); `-` reads stdin; repeatable |
| `--flake INSTALLABLE` | append one flake output `<flakeref>[#<attrpath>]`; repeatable; requires the `flakes` feature; not accepted by `parse` |
| `-A, --attr ATTR` | select attribute path ATTR from the result; not accepted by `parse` |
| `--arg NAME EXPR` / `--argstr NAME STR` | pass an expression / a string as top-level function argument NAME; not accepted by `parse` |
| `-I, --include PATH` | prepend a search-path entry (as in `NIX_PATH`; `prefix=path` form allowed). Repeatable. |
| `--option NAME VALUE` | override a nix.conf setting |
| `--find-file` | (`instantiate`) resolve each source argument as a `NIX_PATH` name and print its absolute path, without evaluation |

`FILEISH` follows the legacy `nix-build`/`nix-instantiate` forms: a regular
path; a directory (loads `default.nix`); a lookup path such as `<nixpkgs>`;
an HTTP(S) tarball URL; `channel:NAME` (the corresponding
`channels.nixos.org/NAME/nixexprs.tar.xz`); or `flake:FLAKEREF` (fetch the
flake source and load its `default.nix`, requiring the `flakes` feature).
Prefix a special-looking local filename with `./` to disambiguate it. These
are source inputs and can be mixed freely; `--flake`, by contrast, is the
explicit typed flake-output/installable form.

A `--flake <flakeref>[#<attr>]` fragment resolves against the outputs the
command cares about: `build`/`run`/`switch` try `packages.<system>.<attr>` then
`legacyPackages.<system>.<attr>`; `shell` tries `devShells.<system>.<attr>`
first; `run` tries `apps.<system>.<attr>` first (a flake `app`, execed
directly), then packages; `switch --nixos/--darwin/--home-manager` resolves the
`nixosConfigurations`/`darwinConfigurations`/`homeConfigurations` toplevel;
`eval` (and the other value commands) resolve `<attr>` from the flake root
first. An empty fragment (`--flake .#`) selects the `default` output for the
derivation-building commands, or the whole flake for `eval`. The system is
resolved once (from the host) and baked in, so lowering never depends on
`builtins.currentSystem`.

**Flake `nixConfig`.** A flake's `nixConfig` attrset is layered onto the settings
exactly like `--option NAME VALUE` (config < `--option` < `nixConfig`), read up
front by fetching the flake source and importing only its `flake.nix`
`nixConfig` (no outputs/inputs/store) so it applies before any daemon
connection. Remote flakes are fetched into the shared disk cache, so the real
evaluation reuses the download. Values are coerced as nix.conf expects: lists
join with spaces, bools become `true`/`false`.

**Pure evaluation.** A `--flake` installable evaluates in *pure mode* by default
(matching Nix's flake commands): `builtins.getEnv` returns `""`, filesystem
reads are confined to the store and the flake's own source tree, `<...>` /
`NIX_PATH` search-path lookups are rejected, and `builtins.fetchTree` /
`fetchGit` / `fetchTarball` / `fetchurl` / `fetchMercurial` must be
content-locked (a `narHash` / `rev` / `sha256`). Pass `--impure` to lift all of
these. `builtins.currentSystem` / `currentTime` are also unavailable in pure
mode (a flake must take `system` as an output argument). Plain expression/file
inputs (`-E`, a path) are impure as before.

### The flake command

`fix flake <subcommand> [flakeref]` inspects and manages a flake; the flakeref
defaults to `.`. All subcommands require the `flakes` feature.

| Subcommand | Effect |
|---|---|
| `metadata` | print the flake's resolved path, locked `narHash`, description, revision, last-modified time, and declared inputs |
| `show` | print the outputs as a tree (`packages`/`apps`/`devShells`/`checks` per system; `nixosConfigurations`, `overlays`, `templates`, … flat) |
| `check` | evaluate every output and report the ones that fail (non-zero exit on any failure) |
| `lock` | complete `flake.lock` for the cwd flake — add missing inputs, keep every existing pin |
| `update [inputs…]` | re-pin the cwd flake's lock: all inputs, or only the named ones (the rest keep their current pins) |

`update`/`lock` are a first-class lock operation (`Engine.updateFlakeLock`):
they fetch the inputs and (re)write `flake.lock` directly, without evaluating
`outputs`. Untouched inputs are copied forward from the existing lock, so
`flake update nixpkgs` re-pins only `nixpkgs`. `getFlake`'s auto-lock-on-first-
eval is just the "pin everything" caller of the same machinery.

### Evaluation / output

| Flag | Meaning |
|---|---|
| `--json` / `--xml` | (`eval`, `repl`) render the value as JSON / XML instead of Nix; `--no-location` omits XML source positions. `parse` always writes JSON and accepts `--json` as a compatibility no-op |
| `--raw` | (`eval`) coerce to a string and write it without quotes or a trailing newline |
| `--strict` | recursively force attr values + list items before writing |
| `--read-write-mode` | (`eval`) register evaluated derivations and store-backed fetched sources while still printing the evaluated value |
| `--impure` | disable pure evaluation for `--flake` installables (see below). Restores `builtins.getEnv`, out-of-tree filesystem reads, `<...>`/`NIX_PATH` lookups, and unlocked fetches |
| `--experimental-features FEATS` / `--extra-experimental-features FEATS` | space-separated experimental features to enable (replace / append), Nix-style. Available: `pipe-operators` — the `\|>` / `<\|` pipe operators (sugar for application) → [syntax/nix-syntax.md](syntax/nix-syntax.md); `fetch-tree` — gates a direct `builtins.fetchTree` call; `flakes` — gates the flake builtins (`getFlake`, `parseFlakeRef`, `flakeRefToString`) and the `--flake` installable, and implies `fetch-tree`; `coerce-integers` — permits integer-to-string coercion in string concatenation. All off by default; a disabled builtin raises a hard (tryEval-uncatchable) error. |
| `--deprecated-features FEATS` / `--extra-deprecated-features FEATS` | replace / append Lix-compatible legacy behavior switches. Available: `cr-line-endings`, `floating-without-zero`, `floor-ceil-corrupt-integers`, `nix-path-shadow`, `nul-bytes`, `or-as-identifier`, `rec-set-dynamic-attrs`, `rec-set-merges`, `rec-set-overrides`, and `tokens-no-whitespace`. |
| `--workers N` | worker threads; default `min(12, cpu_count)` (1 if single-threaded) → [parallel/workers.md](parallel/workers.md) |
| `--no-compile-cache` | do not read or write the persistent compiled-chunk cache; compile everything from source → [compiler/chunk-cache.md](compiler/chunk-cache.md) |
| `--compile-cache-dir DIR` | compiled-chunk cache root (default `$XDG_CACHE_HOME/fix/chunks`, else `~/.cache/fix/chunks`) → [compiler/chunk-cache.md](compiler/chunk-cache.md) |
| `--gc-budget SIZE` | evaluator-heap budget before collection kicks in (MiB, or a `k`/`m`/`g` suffix; `0` = never collect; default RAM-scaled) → [gc.md](gc.md) |
| `--hugetlb auto\|on\|off` | back the evaluation heap with explicit 2 MB huge pages (default `auto`: only when the kernel pool has ≥256 MB unreserved capacity). Provision the pool with `sysctl vm.nr_hugepages=N` → [perf/hugetlb.md](perf/hugetlb.md) |
| `--show-trace` | full evaluation traces on error |
| `--debugger` (eval, repl) | pause into the interactive debug console at `builtins.break` and on evaluation errors; forces `--workers=1`. See [The debugger](#the-debugger). |
| `--color[=auto\|always\|never]` / `--no-color` | color diagnostics; auto disables color off-TTY or under `NO_COLOR`, then selects truecolor from `COLORTERM`, 256-color from `TERM`, or ANSI-16 |
| `--progress` / `--no-progress` | enable / disable timestamped progress records on stderr |
| `-v, --verbose` | increase progress detail (checks at `-v`; parse/compile completions at `-vv` and openings at `-vvv`) and daemon build verbosity |
| `--no-tui` (repl) | keep the interactive editor and inline output, but do not open full-screen `:debug` or `:vm` workspaces |

### Store links & realization (`instantiate`/`build`/`run`/`shell`/`switch`)

| Flag | Meaning |
|---|---|
| `--store STORE-URI` | select a `daemon`/`unix://`, `ssh-ng://`, or `tcp://` endpoint. Lix `any`, `legacy`, and `legacy-combined` selectors use its stable worker protocol. Native `local`/`auto`/chroot and XP-only endpoints are not implemented and fail explicitly; fix never delegates them to locally installed Nix/Lix programs. |
| `-o, --out-link NAME` | name of the result symlink (`build`; default `result`); `--no-out-link` (alias `--no-link`) skips it |
| `--dry-run` | (`build`) report the daemon's build/substitution plan without realizing or linking it |
| `-Q, --no-build-output` | suppress builder stdout/stderr |
| `--drv-link NAME` / `--add-drv-link` | name of / also create the `.drv` symlink (`build`/`instantiate`; default `derivation`) |
| `--add-root PATH` / `--indirect` | create the link at PATH and register it as a (optionally indirect) GC root (`build`/`instantiate`) |
| `--check` / `--repair` | rebuild and verify outputs are unchanged / repair corrupted store paths |
| `-j, --max-jobs N\|auto` / `--cores N` | daemon build parallelism (folded into `--option` overrides, applied via the worker protocol); also accepted by `eval`/`parse`/`instantiate` like legacy `nix-instantiate` |
| `--fallback` | build from source if a substitute fails |
| `-k, --keep-going` | continue with independent builds after a failure |
| `-K, --keep-failed` | keep the build tree of failed builds |
| `--max-silent-time SECS` / `--timeout SECS` | abort builds silent/running too long (`0` = no limit) |
| `-p, --packages NAMES...` | (`shell`) packages (attr paths) from `<nixpkgs>`, e.g. `-p ripgrep jq` |

### System activation (`switch`)

The optional action is `switch` (default), `boot`, `test`, `build`, or `dry-activate`. Select the platform with `--nixos`, `--darwin`, or `--home-manager`. Remote activation is pending a native closure-transfer transport; fix does not call `nix-copy-closure` or `nix-env`.

The action, when present, must be the first argument after `fix switch`, for
example `fix switch build --nixos`. This command is experimental: its scope and
interface are still being worked out and are likely to change.

### Introspection / trace flags

| Flag | Meaning |
|---|---|
| `--vm-trace[=PATH]` | record VM execution (default `-`, i.e. stderr); needs a `-Dvm-trace` build |
| `--vm-trace-format text\|binary` | trace encoding (default `text`) |
| `--vm-trace-max-events N` | cap recorded events (default `0` = unlimited) |
| `--vm-trace-main-only` | record only the main thread's fiber |
| `--thunks-log PATH` | per-thunk lifecycle log (PATH required — `--thunks-log PATH` or `=PATH`; needs a `-Dthunks-log` build) |
| `--timeline[=PATH]` | Perfetto wall-clock timeline (default `fix-timeline.json`) |
| `--stats` | after evaluation, print heap / intern / chunk / deferred / scheduler / speculation counters to stderr, plus any `-Dprof-main` / `-Dprof-path` reports |
| `--mem-report[=dump]` | print peak-RSS attribution at teardown; `dump` also lists registered VMAs |
| `--gc-report` | print the collection/pause/live-set summary at teardown |

### Parallelism debug toggles

Speculation and fan-out are **on by default**; these toggles disable them for controlled comparisons and divergence isolation.

| Flag | Meaning |
|---|---|
| `--no-spec-thunks` | disable speculative thunk evaluation → [parallel/speculation.md](parallel/speculation.md) |
| `--no-fanout` | disable strict-argument fan-out → [parallel/speculation.md](parallel/speculation.md) |
| `--timeline-flows off\|all` | record all scheduler steal-flow arrows or none (default `all`) |

Use the disable toggles to isolate whether a wrong parallel result (or a hang) comes from speculation vs fan-out: rerun with each disabled and see which one restores correctness.

## Using the debug tools

- **`disasm`** — read what the compiler emitted per chunk, with source spans and constant-pool annotation. The first stop when a bytecode-level bug is suspected; pair with [compiler/pipeline.md](compiler/pipeline.md) to map source→ops and [vm/dispatch.md](vm/dispatch.md) to map ops→handlers. Flags: `--eval` (evaluate first, then disassemble every chunk that compiled), `--stats` (corpus statistics instead of a listing), `--chunk N`, `--no-recurse`, `--no-source`, `--no-constants`, `--no-bytes`, `--no-pager`.
- **`--stats`** — append evaluator statistics to stderr from `eval`, `instantiate`, `build`, `run`, `shell`, `repl`, or `switch`; `disasm --stats` retains its bytecode-corpus report. Build-like commands snapshot the evaluator report before releasing the language heap for the daemon build phase.
- **`--vm-trace` + `trace`** — in a `-Dvm-trace` build, capture a VM event stream (`--vm-trace-format binary` for volume, `--vm-trace-main-only` to drop helper noise), then inspect it with the `trace` subcommand: `trace dump` pretty-prints the binary trace as text, `trace diff` walks two binary traces to the first divergent event. The `trace` subcommand reads the binary format only.
- **`--thunks-log` + `fix thunks diff`** — the divergence workflow, available only in a `-Dthunks-log` build. When a `--workers=N` run gives a wrong answer a `--workers=1` run doesn't, record `--thunks-log` for both, then `fix thunks diff A B`. It keys thunk outcomes by the joint `(creator, target)` source-location pair — each a `(file, line, col)` triple, stable across runs even though chunk/thunk ids are not; creator alone collides across let-bindings sharing an outer span and target alone collides at synthetic `?:0:0` spans, so the pair is unique per thunk-creation site — and reports the earliest locations whose resolve/errored/reset outcome multisets differ. Filters narrow it further: `--asymmetric` (one side produced an outcome the other never did — the speculation-race smoking gun), `--novel-in b` (only where B forced something A never reached), `--by-kind` (compare by kind+discriminant, ignoring value contents, to suppress iteration-order noise), `--max-divergences N` (default 30), `--max-outcomes N` (default 5). See [runtime/thunks.md](runtime/thunks.md).
- **`--timeline`** — emits the same structured spans as progress plus profile-only worker quanta, GC pauses, demand waits, metrics, counters, and steal flows as Perfetto JSON. Load it in Perfetto to *see* the serial critical path that bounds wall time → [perf/model.md](perf/model.md).

The `--vm-trace` and `--thunks-log` flags only do anything on a build compiled with the matching `-D` probe (`-Dvm-trace`, `-Dthunks-log`); the `-Dprof-main` / `-Dprof-path` reports surface through `--stats`. `--timeline` needs no rebuild — the timeline probe is always compiled in and runtime-gated. Exercising a `-Dprof-*` probe means a rebuild. See [perf/probes.md](perf/probes.md) and [build.md](build.md).

Code: `src/main.zig` / `src/cli/`
