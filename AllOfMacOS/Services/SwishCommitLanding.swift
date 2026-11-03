import AppKit

// MARK: - The end of a commit (N333-06)

/// What a title-bar commit does once its window has moved. 3.3.3 ran the
/// haptic, the activation, the pointer move and a motion queued behind the
/// commit even when AOM or the window's app had been paused, or the snap had
/// stopped, while the move landed (Native Tiling's 0.35 s read-back and
/// `applySnap`'s completion alike). The move itself had started already; the
/// bookkeeping always runs (the history keeps where the window went, the
/// preview goes, the gesture state is cleared), and what reaches the user
/// beyond the move runs only when the follow-ups are allowed, asked once as
/// it lands. Each step is a closure, so the order can be tested without
/// windows. Main thread only.
struct SwishCommitLanding {
    /// Keeps the snap in the history (or forgets a restore).
    var record: @MainActor () -> Void
    /// Hides the preview, when the follow-ups are not allowed.
    var hidePreview: @MainActor () -> Void
    /// Animates the preview onto the frame the window took, then fades it.
    var settlePreview: @MainActor () -> Void
    var haptic: @MainActor () -> Void
    /// Raises the window and activates its app (Swish's "activate after snapping").
    var activate: @MainActor () -> Void
    /// Puts the pointer on the window's title bar (Swish's "move cursor").
    var warpPointer: @MainActor () -> Void
    /// Clears the gesture state.
    var reset: @MainActor () -> Void
    /// Applies the motion that waited for this commit, if any.
    var resumeQueued: @MainActor () -> Void

    /// The settings that ask for each follow-up.
    struct Options: Equatable {
        var haptics = true
        var activate = true
        /// Off for a hotkey's commit: the pointer stays where it is.
        var movePointer = false
    }

    @MainActor func land(followUps allowed: Bool, options: Options) {
        record()
        guard allowed else {
            hidePreview()
            reset()
            return
        }
        if options.haptics { haptic() }
        settlePreview()
        if options.activate { activate() }
        if options.movePointer { warpPointer() }
        reset()
        resumeQueued()
    }

    /// Pure: whether the follow-ups may run as a commit lands. The generation
    /// it started in still holds (the snap did not stop, the Mac did not
    /// sleep, no chain took the gestures to another window), its window still
    /// answered, and the rules of a delayed window step allow it
    /// (`SwishDelayedTasks.mayRun`: AOM through the gate of the commit's
    /// input, the window's app not paused, the screen not locked, the app
    /// still running).
    static func followUpsAllowed(sameGeneration: Bool, windowAnswers: Bool, allowed: Bool, appPaused: Bool,
                                 screenLocked: Bool, appRunning: Bool) -> Bool {
        sameGeneration && windowAnswers
            && SwishDelayedTasks.mayRun(allowed: allowed, appPaused: appPaused, screenLocked: screenLocked,
                                        appRunning: appRunning)
    }

    /// Pure: whether `bringForward` may raise a window and activate its app,
    /// whoever asks (a landing commit, a Space move): the snap is on, AOM is
    /// neither switched off nor paused (`gateAllows`: the `.system` gate, the
    /// pause whatever the input) and the window's app is not paused.
    static func mayBringForward(active: Bool, gateAllows: Bool, appPaused: Bool) -> Bool {
        TitleBarWindowSnap.mayMoveWindow(active: active, gateAllows: gateAllows) && !appPaused
    }
}
