//! MUS format (DMX's simplified MIDI derivative) parsing and sequencing. Pure format logic — no
//! SDL, no synth; the consumer maps Events onto its synthesizer. Reference: doom/mus2mid.c and
//! the DMX MUS format.

const std = @import("std");

pub const Error = error{InvalidMus};

/// Validate a MUS lump and return the raw event-stream slice. Header: "MUS\x1a" magic, u16le
/// score length, u16le score start offset (channel/instrument counts follow; the sequencer
/// doesn't need them).
pub fn parseScore(lump: []const u8) Error![]const u8 {
    if (lump.len < 12 or !std.mem.eql(u8, lump[0..4], "MUS\x1a")) return Error.InvalidMus;
    const score_len = std.mem.readInt(u16, lump[4..6], .little);
    const score_start = std.mem.readInt(u16, lump[6..8], .little);
    if (@as(usize, score_start) + score_len > lump.len) return Error.InvalidMus;
    return lump[score_start..][0..score_len];
}

pub const Event = union(enum) {
    note_off: struct { ch: u8, note: u8 },
    note_on: struct { ch: u8, note: u8, vol: u8 },
    /// 0-255, 128 = centered (maps to MIDI pitch wheel as value * 64).
    pitch_bend: struct { ch: u8, value: u8 },
    /// MUS system event kind 10-14 (all-sounds-off .. reset-all-ctrl).
    system: struct { ch: u8, kind: u8 },
    /// MUS controller 1-9 (MUS numbering; consumer maps to MIDI CC).
    controller: struct { ch: u8, ctrl: u8, value: u8 },
    program_change: struct { ch: u8, preset: u8 },
    end_of_score,
};

/// Walks a MUS score on a sample clock. Per render quantum: drain popEvent() until null,
/// advance() to consume delay time, render that many frames, repeat. Malformed or truncated
/// data ends the score gracefully instead of erroring (matches how lumps fail in the wild).
pub const Sequencer = struct {
    score: []const u8,
    samples_per_tick: usize, // MUS delay ticks run at 140Hz
    pos: usize = 0,
    pending: usize = 0, // samples until the next event is due
    ended: bool = false,
    last_vol: [16]u8 = [_]u8{100} ** 16,

    pub fn init(score: []const u8, samples_per_tick: usize) Sequencer {
        return .{ .score = score, .samples_per_tick = samples_per_tick };
    }

    pub fn reset(self: *Sequencer) void {
        self.pos = 0;
        self.pending = 0;
        self.ended = false;
    }

    /// The next event if one is due now; null while a delay is pending or after the score
    /// ended.
    pub fn popEvent(self: *Sequencer) ?Event {
        if (self.ended or self.pending > 0) return null;
        if (self.pos >= self.score.len) return self.end();
        const desc = self.byte();
        const ch: u8 = desc & 0x0F;
        const ev: Event = switch ((desc >> 4) & 0x7) {
            0 => .{ .note_off = .{ .ch = ch, .note = self.byte() & 0x7F } },
            1 => blk: {
                const key = self.byte();
                if (key & 0x80 != 0) self.last_vol[ch] = self.byte() & 0x7F;
                break :blk .{ .note_on = .{ .ch = ch, .note = key & 0x7F, .vol = self.last_vol[ch] } };
            },
            2 => .{ .pitch_bend = .{ .ch = ch, .value = self.byte() } },
            3 => blk: {
                const kind = self.byte() & 0x7F;
                if (kind < 10 or kind > 14) return self.end(); // malformed
                break :blk .{ .system = .{ .ch = ch, .kind = kind } };
            },
            4 => blk: {
                const ctrl = self.byte() & 0x7F;
                const value = self.byte() & 0x7F;
                if (ctrl == 0) break :blk .{ .program_change = .{ .ch = ch, .preset = value } };
                if (ctrl > 9) return self.end(); // malformed
                break :blk .{ .controller = .{ .ch = ch, .ctrl = ctrl, .value = value } };
            },
            6 => return self.end(), // score end marker
            else => return self.end(), // types 5/7: never emitted by DMX tools
        };
        if (self.ended) return self.end(); // byte() ran past the end mid-event
        if (desc & 0x80 != 0) self.readDelay();
        return ev;
    }

    /// Consume up to `max` samples of the pending delay; returns how many were consumed
    /// (0 means an event is due or the score has ended).
    pub fn advance(self: *Sequencer, max: usize) usize {
        const n = @min(max, self.pending);
        self.pending -= n;
        return n;
    }

    fn end(self: *Sequencer) Event {
        self.ended = true;
        return .end_of_score;
    }

    fn byte(self: *Sequencer) u8 {
        if (self.pos >= self.score.len) {
            self.ended = true;
            return 0;
        }
        defer self.pos += 1;
        return self.score[self.pos];
    }

    fn readDelay(self: *Sequencer) void {
        var ticks: usize = 0;
        while (true) {
            const b = self.byte();
            ticks = (ticks << 7) | (b & 0x7F);
            if (b & 0x80 == 0 or self.ended) break;
        }
        self.pending = ticks * self.samples_per_tick;
    }
};
