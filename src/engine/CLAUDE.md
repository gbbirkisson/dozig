# src/engine — porting Doom C modules to Zig

Zig rewrites of the original Doom C modules (`../../doom/*.c`), swapped in one at a
time behind a build seam. A module is "ported" by adding its basename to the
`ported` array in `../../build.zig`; that drops the matching `<name>.c` from the C
build and force-links the Zig file here in its place. The Zig file must `export`
the exact C-ABI symbols the remaining C engine links against.

`m_random.zig`, `m_fixed.zig`, and `tables.zig` are the reference examples — a new
port should look like them.

## The endgame

The goal is a **fully idiomatic-Zig engine** — the bridge, the C-ABI types, and
the dependence on `doom/*.h` are transition scaffolding, not the destination.
Every port is a step toward removing that scaffolding:

- When the *last C caller* of a module is ported, delete that module's **C-ABI
  bridge** — nothing links the `export`ed symbols anymore.
- When *no C files remain* that `#include` a given `doom/*.h`, that **header**
  goes too (and eventually the whole `doom/` tree disappears).
- What's left is idiomatic Zig calling idiomatic Zig: Zig types instead of
  `c_int`/`[*c]`, real errors, `std.mem.Allocator`, methods on structs — no
  `export`, no `extern`, no C headers.

So write the idiomatic layer as the code you'd actually *want* to keep; the bridge
only exists to keep the still-C engine running until it's gone.

## How a port file is laid out

Write each `src/engine/<name>.zig` in this order, top to bottom:

1. **Header** — a `//!` module doc whose first line is a title stating what the
   module is and which C file it ports, e.g.
   `//! Fixed-point (16.16) arithmetic (port of doom/m_fixed.c).`
2. **ELI5** — a short `//!` block in plain language: what this thing *is* and why,
   for someone who has never seen this Doom subsystem. Concrete over formal; a
   tiny worked example is welcome. (Follows the title, blank `//!` line between.)
3. **Roughly four sections**, separated by `// ----- <section> -----` banner
   comments. The set can vary a bit (a data-only module has no real functions; a
   tiny one may fold sections together):
   - **Constants** — the `const` / `pub const` values and types the module needs.
     (Usually just leads the file right after the header; a banner is optional.)
   - **Idiomatic Zig API** — the real implementation in Zig style (`pub fn`,
     `pub const`, Zig types and errors). This is what *future Zig modules* call.
   - **C-ABI bridge** — thin `export fn` / `export var` wrappers exposing the
     exact symbols the C engine still calls, each delegating to the idiomatic API.
   - **Tests** — `test` blocks that verify behavior.

## The two-layer convention (idiomatic API + C-ABI bridge)

- **Export only** the symbols C actually references — functions, and non-`static`
  globals other translation units use. Everything else stays private Zig state.
- Each idiomatic item documents its C-engine equivalent
  (`/// C engine equivalent: FixedMul (doom/m_fixed.c).`) so the mapping survives
  deleting the bridge.
- The bridge is **temporary**: when the last C caller of a module is ported away,
  delete that module's bridge; the idiomatic API remains.
- Keep C-visible behavior **bit-exact** wherever the playsim/demos depend on it
  (see `finesine` / `m_random`), and add a comment where you *deliberately* don't
  (see `tantoangle`).

## Tests

- Prefer **bit-exact parity against vanilla** for anything demo-critical (sample
  the real Doom values, e.g. `finesine`); use **self-consistency** checks
  (monotonicity, endpoints, ranges) where an exact match isn't required or
  possible.
- Run one file's tests with `zig test src/engine/<name>.zig`.

## Only `.c` files are swapped — headers stay

The port drops `doom/<name>.c` from the compilation, but the matching `.h` stays
and is still `#include`d by C callers. So the C side keeps its macros
(`ANGLETOFINESHIFT`, `FRACUNIT`, tag enums, …) and `extern` declarations from the
header; the Zig port only supplies the *definitions* those declarations promise.
If you port a C file that *uses* one of those macros, the Zig version needs its
own copy — macros don't cross the C→Zig boundary, only linked symbols do.

## Consuming a port from Zig (not wired yet)

Today only the C engine calls into a port, through the C-ABI bridge. The build
gives each port module the `interop` and `config` imports, but nothing imports a
*port* module — so a future Zig module (e.g. a ported `p_enemy` wanting to call
`m_random.play()` directly) cannot yet `@import` another port. Wiring
port-to-port Zig imports is a deliberate next step: add the target port to the
consumer's import table in `../../build.zig` when the first such case appears.

## Building

- `zig build run` — Zig ports active where they exist, C otherwise.
- `zig build -Dcengine run` — all C game logic (the baseline to diff against).
