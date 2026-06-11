const std = @import("std");
const translate_c = @import("translate_c");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build original C doom or zig version
    const original = b.option(
        bool,
        "original",
        "Build the original C Doom (no Zig)",
    ) orelse false;

    // Render resolution
    const resx = b.option(u32, "resx", "Horizontal resolution") orelse 1280;
    const resy = b.option(u32, "resy", "Vertical resolution") orelse 800;
    if (resx == 0 or resx % 320 != 0 or resy % 200 != 0 or resx / 320 != resy / 200) {
        std.debug.print(
            \\error: invalid -Dresx={d} -Dresy={d}
            \\  Resolution must be an integer multiple of Doom's native 320x200
            \\  (same factor on both axes): 320x200, 640x400, 960x600, 1280x800, ...
            \\
        , .{ resx, resy });
        std.process.exit(1);
    }

    // Create doom_zig module
    const doom_zig = if (original)
        // Use the original C code
        b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .sanitize_c = .off,
            .link_libc = true,
        })
    else
        // Use new zig module
        b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = .off,
        });

    // Setup source files and compile flags
    var doom_c_src: std.ArrayList([]const u8) = .empty;
    var doom_c_flags: std.ArrayList([]const u8) = .empty;

    // Bare nessecities
    try doom_c_src.appendSlice(b.allocator, &.{
        "am_map.c",
        "d_event.c",
        "d_items.c",
        "d_iwad.c",
        "d_loop.c",
        "d_main.c",
        "d_mode.c",
        "d_net.c",
        "doomdef.c",
        "doomgeneric.c",
        "doomstat.c",
        "dstrings.c",
        "dummy.c",
        "f_finale.c",
        "f_wipe.c",
        "g_game.c",
        "hu_lib.c",
        "hu_stuff.c",
        "i_endoom.c",
        "i_input.c",
        "i_joystick.c",
        "i_scale.c",
        "i_sound.c",
        "i_system.c",
        "i_timer.c",
        "i_video.c",
        "info.c",
        "m_argv.c",
        "m_bbox.c",
        "m_cheat.c",
        "m_config.c",
        "m_controls.c",
        "m_fixed.c",
        "m_menu.c",
        "m_misc.c",
        "m_random.c",
        "memio.c",
        "p_ceilng.c",
        "p_doors.c",
        "p_enemy.c",
        "p_floor.c",
        "p_inter.c",
        "p_lights.c",
        "p_map.c",
        "p_maputl.c",
        "p_mobj.c",
        "p_plats.c",
        "p_pspr.c",
        "p_saveg.c",
        "p_setup.c",
        "p_sight.c",
        "p_spec.c",
        "p_switch.c",
        "p_telept.c",
        "p_tick.c",
        "p_user.c",
        "r_bsp.c",
        "r_data.c",
        "r_draw.c",
        "r_main.c",
        "r_plane.c",
        "r_segs.c",
        "r_sky.c",
        "r_things.c",
        "s_sound.c",
        "sha1.c",
        "sounds.c",
        "st_lib.c",
        "st_stuff.c",
        "statdump.c",
        "tables.c",
        "v_video.c",
        "w_checksum.c",
        "w_file.c",
        "w_file_stdc.c",
        "w_main.c",
        "w_wad.c",
        "wi_stuff.c",
        "z_zone.c",
    });

    if (original) {
        // We need these to run the original C code
        try doom_c_src.appendSlice(b.allocator, &.{
            "doomgeneric_sdl.c",
            "i_cdmus.c",
            "i_sdlmusic.c",
            "i_sdlsound.c",
            "mus2mid.c",
        });
    }
    try doom_c_flags.append(b.allocator, "-DFEATURE_SOUND");

    // Resolution defines for the C engine
    try doom_c_flags.append(b.allocator, b.fmt("-DDOOMGENERIC_RESX={d}", .{resx}));
    try doom_c_flags.append(b.allocator, b.fmt("-DDOOMGENERIC_RESY={d}", .{resy}));

    // Inject C source files into the project
    doom_zig.addCSourceFiles(.{
        .root = b.path("doom"),
        .files = doom_c_src.items,
        .flags = doom_c_flags.items,
    });

    if (original) {
        // The original C backend uses SDL2 (+mixer for sound).
        doom_zig.linkSystemLibrary("SDL2_mixer", .{});
    } else {
        const translate_c_dep = b.dependency("translate_c", .{});

        const sdl_dep = b.dependency("sdl", .{
            .target = target,
            // Build SDL optimized regardless of our mode: in Debug it is
            // compiled with UBSan, which references __ubsan_handle_* symbols we
            // don't link a runtime for. We never debug into SDL itself.
            .optimize = .ReleaseFast,
            .preferred_linkage = .static,
        });
        const sdl_lib = sdl_dep.artifact("SDL3");
        doom_zig.linkLibrary(sdl_lib);

        // Translate SDL3's headers into a Zig module imported as `c`.
        const sdl_translator: translate_c.Translator = .init(translate_c_dep, .{
            .c_source_file = b.addWriteFiles().add("c.h",
                \\#define SDL_DISABLE_OLD_NAMES
                \\#include <SDL3/SDL.h>
                \\#include <SDL3/SDL_revision.h>
                \\#define SDL_MAIN_HANDLED
                \\#include <SDL3/SDL_main.h>
            ),
            .target = target,
            .optimize = optimize,
        });
        sdl_translator.linkLibrary(sdl_lib);
        doom_zig.addImport("sdl", sdl_translator.mod);

        // Translate doomkeys.h (pure macros, no includes) into a `doomkeys`
        const doomkeys_translator: translate_c.Translator = .init(translate_c_dep, .{
            .c_source_file = b.path("doom/doomkeys.h"),
            .target = target,
            .optimize = optimize,
        });
        doom_zig.addImport("doomkeys", doomkeys_translator.mod);

        // Expose the same resolution to the Zig backend.
        const options = b.addOptions();
        options.addOption(u32, "DOOMGENERIC_RESX", resx);
        options.addOption(u32, "DOOMGENERIC_RESY", resy);
        doom_zig.addImport("config", options.createModule());
    }

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
