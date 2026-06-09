const std = @import("std");

pub fn build(b: *std.Build) !void {
    const io = b.graph.io;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Collect all doom/*.c files
    var doom_c_src: std.ArrayList([]const u8) = .empty;
    {
        var doom_c_dir = try b.build_root.handle.openDir(io, "doom", .{ .iterate = true });
        defer doom_c_dir.close(io);
        var it = doom_c_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".c")) {
                try doom_c_src.append(b.allocator, b.dupe(entry.name));
            }
        }
    }

    // Create module wrapping the original doom C implementation
    const doom_c = b.addTranslateC(.{
        .root_source_file = b.path("doom/doomgeneric.h"),
        .target = target,
        .optimize = optimize,
    });

    // Create module for our doom zig project
    const doom_zig = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Doom's C relies on behavior that is technically undefined in C (e.g. left-shifting
        // negative ints in r_data.c). gcc/clang compile it fine, but Zig enables a C
        // undefined-behavior sanitizer in Debug/ReleaseSafe that traps on it and aborts at
        // startup. Turn it off so the legacy C builds and runs as-is. Only affects C/C++ here;
        // our Zig code (main.zig and anything we port) still gets full Zig safety checks.
        .sanitize_c = .off,
        .imports = &.{
            .{ .name = "doom_c", .module = doom_c.createModule() },
        },
    });

    // Inject C source files into the project
    doom_zig.addCSourceFiles(.{
        .root = b.path("doom"),
        .files = doom_c_src.items,
        .flags = &[_][]const u8{
            "-DFEATURE_SOUND",
            "-DUSE_ZIG_MAIN",
            "-DDOOMGENERIC_RESX=1280",
            "-DDOOMGENERIC_RESY=800",
        },
    });

    // Link libraries
    doom_zig.linkSystemLibrary("SDL2_mixer", .{});

    // Create executable
    const dozig = b.addExecutable(.{
        .name = "dozig",
        .root_module = doom_zig,
    });
    b.installArtifact(dozig);

    const run_cmd = b.addRunArtifact(dozig);
    run_cmd.step.dependOn(b.getInstallStep());
    // Forward trailing args: `zig build run -- -playdemo demo1`, `-warp`, etc.
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
