# dozig

This is a source port of the ID Software source release of DOOM. This repository is used as an
educational tool for myself.

This is a fork from [doomgeneric](https://github.com/ozkl/doomgeneric) that focuses on porting
DOOM to Zig for learning.

## Requirements

```
$ sudo apt install libsdl2-mixer-dev
```

## Run

```bash
# Original C version
$ make dozig
$ ./dozig

# Zig version
$ zig build run
```

## Demos

```
# Run demos
$ zig build run -- -playdemo demo1
$ zig build run -- -timedemo demo1
```
