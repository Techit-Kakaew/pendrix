/// Compile-time switches for features that exist but are parked.
enum Features {
    /// Standup summary (Yesterday / Today / Blockers + AI spoken version). Parked 2026-09-19: no company Claude org yet,
    /// on-device model has no Thai. Flip to true to bring back the button, settings, reminder and route.
    static let standup = false
}
