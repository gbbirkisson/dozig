# Zig engine ports

Zig rewrites of the original Doom C modules (`../../doom/*.c`), swapped in one at
a time. A module is "ported" by listing its basename in the `ported` array in
`../../build.zig`; that both drops the matching `<name>.c` from the C build and
force-links the Zig file here in its place.

## The two-layer convention

Every port has two layers:

1. **Idiomatic Zig API** (`pub` functions/types) — the real implementation, in
   Zig style. This is what *future Zig modules* import and call.
2. **C-ABI bridge** (`export fn` / `export var`) — thin wrappers exposing the
   exact symbols the remaining C engine still calls, delegating to layer 1.
   Temporary.

Export **only** the symbols C actually references (functions, and non-`static`
globals that other translation units use). Everything else stays private Zig
state. Each idiomatic function documents its C-engine equivalent (e.g.
`C engine equivalent: P_Random`) so the mapping survives deleting the bridge.
When the last C caller of a module is ported away, delete that module's bridge;
the idiomatic API remains.

See `m_random.zig` for the reference example.

## Consuming a port from Zig (not wired yet)

Today only the C engine calls into a port, through the C-ABI bridge. The build
gives each port module the `interop` and `config` imports, but nothing imports a
*port* module — so a future Zig module (e.g. a ported `p_enemy` wanting to call
`m_random.play()` directly) cannot yet `@import` another port. Wiring
port-to-port Zig imports is a deliberate next step: add the target port to the
consumer's import table in `build.zig` when the first such case appears.

## Building

- `zig build run` — Zig ports active where they exist, C otherwise.
- `zig build -Dcengine run` — all C game logic (the baseline to diff against).
