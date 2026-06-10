const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build original C doom or new version
    const original = b.option(
        bool,
        "original",
        "Build the original C Doom (no Zig)",
    ) orelse false;

    // Create module wrapping the original doom C implementation
    const doom_c = b.addTranslateC(.{
        .root_source_file = b.path("doom/doomgeneric.h"),
        .target = target,
        .optimize = optimize,
    });

    // Create doom_zig module
    const doom_zig = if (!original)
        // Use new zig module
        b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = .off,
            .imports = &.{
                .{ .name = "doom_c", .module = doom_c.createModule() },
            },
        })
    else
        // Use the original C code
        b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .sanitize_c = .off,
            .link_libc = true,
        });

    // Setup source files and compile flags
    var doom_c_src: std.ArrayList([]const u8) = .empty;
    var doom_c_flags: std.ArrayList([]const u8) = .empty;

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
        "doomgeneric_sdl.c",
        "doomstat.c",
        "dstrings.c",
        "dummy.c",
        "f_finale.c",
        "f_wipe.c",
        "g_game.c",
        "hu_lib.c",
        "hu_stuff.c",
        "i_cdmus.c",
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
        "mus2mid.c",
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
        try doom_c_src.appendSlice(b.allocator, &.{
            "i_sdlmusic.c",
            "i_sdlsound.c",
        });
        try doom_c_flags.appendSlice(b.allocator, &.{
            "-DFEATURE_SOUND",
            // "-DDOOMGENERIC_RESX=1280",
            // "-DDOOMGENERIC_RESY=800",
        });
    } else {
        try doom_c_flags.append(b.allocator, "-DUSE_ZIG_MAIN");
    }

    // TODO: Remove this from the (non-original) zig build one happy day
    {
        // Inject C source files into the project
        doom_zig.addCSourceFiles(.{
            .root = b.path("doom"),
            .files = doom_c_src.items,
            .flags = doom_c_flags.items,
        });

        // Link libraries
        doom_zig.linkSystemLibrary("SDL2_mixer", .{});
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
