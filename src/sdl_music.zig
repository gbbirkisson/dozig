//! No-op music module. -DFEATURE_SOUND makes doom/i_sound.c reference DG_music_module at link
//! time; This stub becomes the real SDL3 music module when that work happens.

const doom = @import("doom.zig");

var music_devices = [_]doom.SndDevice{
    doom.SNDDEVICE_PAS,
    doom.SNDDEVICE_GUS,
    doom.SNDDEVICE_WAVEBLASTER,
    doom.SNDDEVICE_SOUNDCANVAS,
    doom.SNDDEVICE_GENMIDI,
    doom.SNDDEVICE_AWE32,
};

fn musicInit() callconv(.c) doom.boolean {
    return doom.TRUE;
}

fn musicShutdown() callconv(.c) void {}

fn musicSetVolume(volume: c_int) callconv(.c) void {
    _ = volume;
}

fn musicPause() callconv(.c) void {}

fn musicResume() callconv(.c) void {}

fn musicRegisterSong(data: ?*anyopaque, len: c_int) callconv(.c) ?*anyopaque {
    _ = data;
    _ = len;
    return null;
}

fn musicUnRegisterSong(handle: ?*anyopaque) callconv(.c) void {
    _ = handle;
}

fn musicPlaySong(handle: ?*anyopaque, looping: doom.boolean) callconv(.c) void {
    _ = handle;
    _ = looping;
}

fn musicStopSong() callconv(.c) void {}

fn musicIsPlaying() callconv(.c) doom.boolean {
    return doom.FALSE;
}

export var DG_music_module: doom.MusicModule = .{
    .sound_devices = &music_devices,
    .num_sound_devices = music_devices.len,
    .Init = musicInit,
    .Shutdown = musicShutdown,
    .SetMusicVolume = musicSetVolume,
    .PauseMusic = musicPause,
    .ResumeMusic = musicResume,
    .RegisterSong = musicRegisterSong,
    .UnRegisterSong = musicUnRegisterSong,
    .PlaySong = musicPlaySong,
    .StopSong = musicStopSong,
    .MusicIsPlaying = musicIsPlaying,
    .Poll = null,
};
