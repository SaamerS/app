import Foundation

/// How a microphone's level meter shows how loud it is: a bar that grows with the voice and is still in the quiet. Under
/// Reduce Motion it holds its length and brightens with the voice instead, as the dictation meter does.
public struct LevelMeterLook: Equatable, Sendable {
    /// How much of its track the bar fills, 0 to 1.
    public var fill: Double
    /// How bright the bar is, 0 to 1.
    public var brightness: Double

    public init(level: Double, reduceMotion: Bool) {
        let level = level.isFinite ? min(1, max(0, level)) : 0
        if reduceMotion {
            fill = 1
            brightness = 0.25 + 0.75 * level
        } else {
            fill = level
            brightness = 1
        }
    }
}
