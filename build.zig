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

    // Emscripten/WebAssembly: zig compiles everything to a static library, emcc links it into
    // html+js+wasm under zig-out/www
    const web = target.result.os.tag == .emscripten;
    if (original and web) {
        std.debug.print("error: -Doriginal is not supported for the Emscripten target\n", .{});
        std.process.exit(1);
    }

    // Emscripten's libc headers, required for cross-compiling C for the web:
    // -Dsystem_include_path="$(em-config CACHE)/sysroot/include"
    const system_include_path = b.option(
        std.Build.LazyPath,
        "system_include_path",
        "System header search path for cross-compiling (Emscripten sysroot include dir)",
    );
    if (web and system_include_path == null) {
        std.debug.print("error: '-Dsystem_include_path' is required when building for Emscripten\n", .{});
        std.process.exit(1);
    }

    // Render resolution
    const resx = b.option(u32, "resx", "Horizontal resolution") orelse 1280;
    const resy = b.option(u32, "resy", "Vertical resolution") orelse 800;

    // Mouse sensitivity baseline: raw SDL pixel deltas read far lower than
    // the DOS mouse counts the engine's math expects. The in-game slider
    // adjusts around this (x0.5 .. x1.4).
    const mouse_scale = b.option(f32, "mouse_scale", "Mouse sensitivity scale factor") orelse 3.5;

    // Fullscreen (native only; ignored on Emscripten where the "window" is
    // the canvas).
    const fullscreen = b.option(bool, "fullscreen", "Start fullscreen (native only)") orelse false;
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
            // Emscripten provides libc; the doom C files need its headers.
            .link_libc = if (web) true else null,
        });
    if (web) doom_zig.addSystemIncludePath(system_include_path.?);

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

        // Build SDL optimized regardless of our mode: in Debug it is compiled with UBSan, which
        // references __ubsan_handle_* symbols we don't link a runtime for. We never debug into
        // SDL itself.
        const sdl_dep = if (web)
            b.dependency("sdl", .{
                .target = target,
                .optimize = .ReleaseFast,
                .preferred_linkage = .static,
                // SDL's own C also needs the Emscripten sysroot headers.
                .system_include_path = system_include_path.?,
            })
        else
            b.dependency("sdl", .{
                .target = target,
                .optimize = .ReleaseFast,
                .preferred_linkage = .static,
            });
        const sdl_lib = sdl_dep.artifact("SDL3");
        doom_zig.linkLibrary(sdl_lib);

        // Translate SDL3's headers into a Zig module imported as `c`.
        const sdl_translator: translate_c.Translator = .init(translate_c_dep, .{
            .c_source_file = b.addWriteFiles().add("c.h",
                \\#define SDL_DISABLE_OLD_NAMES
                \\// Neutralize SDL's compile-time asserts before including its headers.
                \\// SDL guards this macro with #ifndef, so our empty definition wins.
                \\// One SDL assert is sizeof(((SDL_Event*)NULL)->padding); translate-c
                \\// renders that null-pointer member access as @as([*c]SDL_Event, null).*
                \\// which Zig 0.17 rejects at comptime (even inside @TypeOf). These are
                \\// C-ABI sanity checks the real SDL library still verifies when it is
                \\// compiled; our header translation only needs the declarations.
                \\#define SDL_COMPILE_TIME_ASSERT(name, x)
                \\#include <SDL3/SDL.h>
                \\#include <SDL3/SDL_revision.h>
                \\#define SDL_MAIN_HANDLED
                \\#include <SDL3/SDL_main.h>
            ),
            .target = target,
            .optimize = optimize,
        });
        if (web) sdl_translator.addSystemIncludePath(system_include_path.?);
        sdl_translator.linkLibrary(sdl_lib);
        doom_zig.addImport("sdl", sdl_translator.mod);

        // Translate doomkeys.h (pure macros, no includes) into a `doomkeys`
        const doomkeys_translator: translate_c.Translator = .init(translate_c_dep, .{
            .c_source_file = b.path("doom/doomkeys.h"),
            .target = target,
            .optimize = optimize,
        });
        doom_zig.addImport("doomkeys", doomkeys_translator.mod);

        // TinySoundFont (music synth): API translated for Zig, implementation
        // compiled as C. tsf.h pulls libc headers, so web needs the sysroot.
        const tsf_translator: translate_c.Translator = .init(translate_c_dep, .{
            .c_source_file = b.path("vendor/tsf.h"),
            .target = target,
            .optimize = optimize,
        });
        if (web) tsf_translator.addSystemIncludePath(system_include_path.?);
        doom_zig.addImport("tsf", tsf_translator.mod);
        doom_zig.addCSourceFile(.{ .file = b.path("vendor/tsf.c") });

        // Embed the GM soundfont as a Zig module; sdl_music.zig loads it
        // with tsf_load_memory. One mechanism for native and wasm.
        const sf_files = b.addWriteFiles();
        _ = sf_files.addCopyFile(b.path("vendor/TimGM6mb.sf2"), "soundfont.sf2");
        const sf_root = sf_files.add("soundfont.zig",
            \\pub const data = @embedFile("soundfont.sf2");
        );
        doom_zig.addAnonymousImport("soundfont", .{ .root_source_file = sf_root });

        // Expose the same resolution to the Zig backend.
        const options = b.addOptions();
        options.addOption(u32, "DOOMGENERIC_RESX", resx);
        options.addOption(u32, "DOOMGENERIC_RESY", resy);
        options.addOption(f32, "DOZIG_MOUSE_SCALE", mouse_scale);
        options.addOption(bool, "DOZIG_FULLSCREEN", fullscreen);
        doom_zig.addImport("config", options.createModule());
    }

    const run_step = b.step("run", "Run the app");

    if (web) {
        // Zig cannot link Emscripten output itself: build a static library and let emcc do the
        // final link into html+js+wasm.
        const dozig_lib = b.addLibrary(.{
            .linkage = .static,
            .name = "dozig",
            .root_module = doom_zig,
        });

        const run_emcc = b.addSystemCommand(&.{"emcc"});
        run_emcc.setCwd(b.path("."));

        // Pass 'dozig_lib' and any static libraries or object files it links with (SDL3) as
        // input files.
        for (dozig_lib.getCompileDependencies(false)) |artifact| {
            if (artifact.isStaticLibrary() or artifact.kind == .obj) {
                run_emcc.addArtifactArg(artifact);
            }
        }

        run_emcc.addArgs(switch (optimize) {
            .Debug => &.{
                "-O0",
                // Preserve DWARF debug information.
                "-g",
                // Use UBSan (full runtime).
                "-fsanitize=undefined",
            },
            .ReleaseSafe => &.{
                "-O3",
                // Use UBSan (minimal runtime).
                "-fsanitize=undefined",
                "-fsanitize-minimal-runtime",
            },
            .ReleaseFast => &.{"-O3"},
            .ReleaseSmall => &.{"-Oz"},
        });
        if (optimize != .Debug) {
            // Perform link time optimization and minify the JavaScript.
            run_emcc.addArg("-flto");
            run_emcc.addArgs(&.{ "--closure", "1" });
        }

        // Doom needs more than emcc's 16MB default memory (zone heap, framebuffers, sound
        // cache).
        run_emcc.addArg("-sALLOW_MEMORY_GROWTH");

        // Asyncify lets SDL_Delay yield to the browser event loop (SDL calls emscripten_sleep
        // when asyncify is linked in). Without it, blocking engine loops — the ~1s screen-melt
        // wipe runs inside a single doomgeneric_Tick — starve the main-thread-serviced audio
        // ScriptProcessorNode, and browsers repeat the last audio buffer (audible as the old
        // song stuttering on level/song changes).
        run_emcc.addArg("-sASYNCIFY");

        // Ship the IWAD inside the page. The engine searches the working directory for IWADs
        // (FILES_DIR "." in d_iwad.c), which is "/" in Emscripten's in-memory filesystem.
        run_emcc.addArgs(&.{ "--embed-file", "doom1.wad@/doom1.wad" });

        // Render into our own editable page (web/shell.html) instead of emcc's
        // stock shell. emcc substitutes `{{{ SCRIPT }}}` in that file with the
        // loader script. The page also carries the JS glue that used to live in
        // a --pre-js blob (stdout/stderr -> console, ANSI stripping).
        run_emcc.addArg("--shell-file");
        run_emcc.addFileArg(b.path("web/shell.html"));

        run_emcc.addArg("-o");
        const dozig_html = run_emcc.addOutputFileArg("dozig.html");

        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = dozig_html.dirname(),
            .install_dir = .{ .custom = "www" },
            .install_subdir = "",
        }).step);

        // `zig build run` serves the page via emrun. Point it straight at the
        // emcc output file (its directory holds the sibling .js/.wasm/.data);
        // install paths are no longer resolvable to plain strings at configure
        // time in the reworked build system, so we use the LazyPath directly.
        const emrun_cmd = b.addSystemCommand(&.{"emrun"});
        emrun_cmd.addFileArg(dozig_html);
        run_step.dependOn(&emrun_cmd.step);
    } else {
        // Create executable
        const dozig = b.addExecutable(.{
            .name = "dozig",
            .root_module = doom_zig,
        });
        b.installArtifact(dozig);

        const run_cmd = b.addRunArtifact(dozig);
        run_cmd.step.dependOn(b.getInstallStep());
        // Forward trailing args: `zig build run -- -playdemo demo1`, `-warp`, etc.
        run_cmd.addPassthruArgs();

        run_step.dependOn(&run_cmd.step);
    }
}
