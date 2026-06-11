//! Hand-declared C interop for the Doom engine: the doomgeneric entry points
//! (doom/doomgeneric.h), the sound module interface (doom/i_sound.h) and the WAD lump API
//! (doom/w_wad.h). These mirror a decade-stable ABI; field order and sizes must match the C
//! headers exactly.

// doom/doomgeneric.h — engine entry points (Zig -> C).
pub extern fn doomgeneric_Create(argc: c_int, argv: [*c][*c]u8) void;
pub extern fn doomgeneric_Tick() void;

/// doom/doomgeneric.h: pixel_t* (uint32_t*), filled by the engine each frame.
pub extern var DG_ScreenBuffer: [*c]u32;

// doom/doomkeys.h translated directly (see build.zig)
pub const keys = @import("doomkeys");

/// doom/doomtype.h: typedef int boolean (via enum {false, true}).
pub const boolean = c_int;
pub const TRUE: boolean = 1;
pub const FALSE: boolean = 0;

/// doom/i_sound.h snddevice_t — only the values our device lists use.
pub const SndDevice = c_int;
pub const SNDDEVICE_SB: SndDevice = 3;
pub const SNDDEVICE_PAS: SndDevice = 4;
pub const SNDDEVICE_GUS: SndDevice = 5;
pub const SNDDEVICE_WAVEBLASTER: SndDevice = 6;
pub const SNDDEVICE_SOUNDCANVAS: SndDevice = 7;
pub const SNDDEVICE_GENMIDI: SndDevice = 8;
pub const SNDDEVICE_AWE32: SndDevice = 9;

/// doom/i_sound.h sfxinfo_t.
pub const SfxInfo = extern struct {
    tagname: ?[*:0]u8,
    name: [9]u8,
    priority: c_int,
    link: ?*SfxInfo,
    pitch: c_int,
    volume: c_int,
    usefulness: c_int,
    lumpnum: c_int,
    numchannels: c_int,
    driver_data: ?*anyopaque,
};

/// doom/i_sound.h sound_module_t. CacheSounds is optional — i_sound.c
/// null-checks it (I_PrecacheSounds).
pub const SoundModule = extern struct {
    sound_devices: [*]const SndDevice,
    num_sound_devices: c_int,
    Init: *const fn (use_sfx_prefix: boolean) callconv(.c) boolean,
    Shutdown: *const fn () callconv(.c) void,
    GetSfxLumpNum: *const fn (sfxinfo: *SfxInfo) callconv(.c) c_int,
    Update: *const fn () callconv(.c) void,
    UpdateSoundParams: *const fn (channel: c_int, vol: c_int, sep: c_int) callconv(.c) void,
    StartSound: *const fn (sfxinfo: *SfxInfo, channel: c_int, vol: c_int, sep: c_int) callconv(.c) c_int,
    StopSound: *const fn (channel: c_int) callconv(.c) void,
    SoundIsPlaying: *const fn (channel: c_int) callconv(.c) boolean,
    CacheSounds: ?*const fn (sounds: [*]SfxInfo, num_sounds: c_int) callconv(.c) void,
};

/// doom/i_sound.h music_module_t. Poll is optional — i_sound.c null-checks it (I_UpdateSound).
pub const MusicModule = extern struct {
    sound_devices: [*]const SndDevice,
    num_sound_devices: c_int,
    Init: *const fn () callconv(.c) boolean,
    Shutdown: *const fn () callconv(.c) void,
    SetMusicVolume: *const fn (volume: c_int) callconv(.c) void,
    PauseMusic: *const fn () callconv(.c) void,
    ResumeMusic: *const fn () callconv(.c) void,
    RegisterSong: *const fn (data: ?*anyopaque, len: c_int) callconv(.c) ?*anyopaque,
    UnRegisterSong: *const fn (handle: ?*anyopaque) callconv(.c) void,
    PlaySong: *const fn (handle: ?*anyopaque, looping: boolean) callconv(.c) void,
    StopSong: *const fn () callconv(.c) void,
    MusicIsPlaying: *const fn () callconv(.c) boolean,
    Poll: ?*const fn () callconv(.c) void,
};

// doom/w_wad.h — WAD lump access (Zig -> C).
pub extern fn W_GetNumForName(name: [*:0]const u8) c_int;
pub extern fn W_CacheLumpNum(lump: c_int, tag: c_int) ?*anyopaque;
pub extern fn W_LumpLength(lump: c_uint) c_int;
pub extern fn W_ReleaseLumpNum(lump: c_int) void;

/// doom/z_zone.h: PU_STATIC = 1 (kept for the entire execution).
pub const PU_STATIC: c_int = 1;
