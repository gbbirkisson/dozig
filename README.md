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

# Compile/Run zig version
$ zig build run
```

## Demos

```
# Run demos
$ zig build run -- -playdemo demo1
$ zig build run -- -timedemo demo1
```
