const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addIncludePath(b.path("doom"));
    mod.addCSourceFiles(.{
        .root = b.path("doom"),
        .files = &[_][]const u8{
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
            "i_sdlmusic.c",
            "i_sdlsound.c",
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
        },
        .flags = &[_][]const u8{
            "-DFEATURE_SOUND",
        },
    });

    // mod.linkSystemLibrary("SDL2", .{});
    mod.linkSystemLibrary("SDL2_mixer", .{});

    const exe = b.addExecutable(.{
        .name = "dozig",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
