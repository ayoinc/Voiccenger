import Foundation
import VCModels

/// Geometries of common USB / HAT microphone arrays.
///
/// Positions and channel orders follow the ODAS reference configurations
/// (github.com/introlab/odas `config/odaslive/*.cfg`, whose `map` entries are 1-based), so a
/// direction reported here matches ODAS for the same board orientation. Azimuth 0° is the board's
/// +x axis, increasing counter-clockwise seen from above (microphones facing up).
public enum ArrayPresets {
    /// Seeed ReSpeaker USB Mic Array v2.0 (XMOS XVF-3000), 6-channel firmware at 16 kHz.
    ///
    /// Four mics on a 32 mm radius (45 mm apart). Device channels: 0 = processed/beamformed
    /// output, 1–4 = raw mics, 5 = playback reference ⇒ `channelMap` [1, 2, 3, 4].
    /// Mic 0 sits on −x and the order runs counter-clockwise (ODAS `respeaker_usb_4_mic_array.cfg`).
    public static let respeaker4 = MicArrayGeometry(
        name: "ReSpeaker USB Mic Array v2.0",
        mics: [
            .init(x: -0.032, y: 0),
            .init(x: 0, y: -0.032),
            .init(x: 0.032, y: 0),
            .init(x: 0, y: 0.032),
        ],
        channelMap: [1, 2, 3, 4])

    /// Seeed ReSpeaker 6-Mic Circular Array kit (2× AC108) on a 46.3 mm radius.
    ///
    /// The driver exposes 8 channels: 0–5 are the mics, 6–7 the playback loopback ⇒ `channelMap`
    /// 0…5. Mic 0 sits at 120° and the order runs counter-clockwise in 60° steps
    /// (ODAS `respeaker_6_mic_array.cfg`).
    public static let respeaker6 = MicArrayGeometry(
        name: "ReSpeaker 6-Mic Circular Array",
        mics: [120.0, 180, 240, 300, 0, 60].map { degrees in
            let radians = degrees * .pi / 180
            return MicArrayGeometry.Point(x: 0.0463 * cos(radians), y: 0.0463 * sin(radians))
        },
        channelMap: [0, 1, 2, 3, 4, 5])

    /// miniDSP UMA-8 v2 in 8-channel raw mode: a centre mic plus six on a 43 mm radius.
    ///
    /// Device channel 0 is the centre mic; channels 1–6 run clockwise starting on +y
    /// (90°, 30°, −30°, −90°, −150°, 150°); channel 7 carries no microphone in raw mode
    /// (ODAS `minidsp.cfg`, which maps 1-based channels 1–7). Coordinates match ODAS exactly
    /// (0.037 m / 0.021 m are its rounded 43 mm-radius hexagon positions).
    public static let uma8 = MicArrayGeometry(
        name: "miniDSP UMA-8",
        mics: [
            .init(x: 0, y: 0),
            .init(x: 0, y: 0.043),
            .init(x: 0.037, y: 0.021),
            .init(x: 0.037, y: -0.021),
            .init(x: 0, y: -0.043),
            .init(x: -0.037, y: -0.021),
            .init(x: -0.037, y: 0.021),
        ],
        channelMap: [0, 1, 2, 3, 4, 5, 6])

    public static let all: [MicArrayGeometry] = [respeaker4, respeaker6, uma8]
}
