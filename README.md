# dozig

This is a source port of the ID Software source release of DOOM. This repository is used as an
educational tool for myself.

This is a fork from [doomgeneric](https://github.com/ozkl/doomgeneric) that focuses on porting
DOOM to Zig for learning.

## Run

```bash
# Compile/Run original C version with clang
$ sudo apt install libsdl2-mixer-dev
$ make dozig
$ ./dozig

# Compile/Run original C version with zig
$ sudo apt install libsdl2-mixer-dev
$ zig build -Doriginal run

# Compile/Run old C engine wrapped with zig
$ zig build -Dcengine run

# Compile/Run ported zig version
$ zig build run

# Compile/Run wasm version
$ embuilder build sysroot
$ zig build run -Dtarget=wasm32-emscripten -Doptimize=ReleaseFast "-Dsystem_include_path=$(em-config CACHE)/sysroot/include"
```

## Demos

```bash
# Run demos
$ zig build run -- -playdemo demo1
$ zig build run -- -timedemo demo1
```

## Test

```bash
$ zig build test
```
