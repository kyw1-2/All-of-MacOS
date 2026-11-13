import Combine
import Foundation

/// Only the values the dashboard displays invalidate its large view tree.
/// Gesture detections and audio playback edges are much more frequent than
/// changes to the dashboard's activity or settings summary.
@MainActor
final class WorkspaceValueProjection<Value: Equatable>: ObservableObject {
    @Published private(set) var value: Value
    private var subscription: AnyCancellable?

    init<P: Publisher>(initial: Value, publisher: P,
                       project: @escaping (P.Output) -> Value) where P.Failure == Never {
        value = initial
        subscription = publisher.map(project).removeDuplicates().sink { [weak self] next in
            guard let self, self.value != next else { return }
            self.value = next
        }
    }
}

struct WorkspaceAudioSummary: Equatable {
    var enabled: Bool
    var eqEnabled: Bool
    var eqPreset: String
    var customApps: Int

    @MainActor
    static func read(_ audio: AppAudioMixerService) -> Self {
        Self(enabled: audio.soundEnabled, eqEnabled: audio.eqEnabled,
             eqPreset: audio.eqPreset, customApps: audio.apps.filter(audio.hasCustomSettings).count)
    }
}

extension WorkspaceValueProjection where Value == [GestureEvent] {
    convenience init(statistics: GestureStatistics) {
        self.init(initial: statistics.events.filter(\.fired), publisher: statistics.$events) {
            $0.filter(\.fired)
        }
    }
}

extension WorkspaceValueProjection where Value == WorkspaceAudioSummary {
    convenience init(audio: AppAudioMixerService) {
        // objectWillChange precedes storage; read after its main-queue turn.
        self.init(initial: .read(audio), publisher: audio.objectWillChange.receive(on: DispatchQueue.main)) { _ in
            .read(audio)
        }
    }
}

/// Calendar bucketing is substantially more expensive than comparing dates.
/// Reuse the week across hover, audio and recording updates; also expire it
/// at midnight or when the user's calendar/time zone changes.
@MainActor
final class WorkspaceWeekCache {
    private struct Key: Equatable {
        let actions: [Date]
        let captures: [Date]
        let copies: [Date]
        let today: Date
        let calendar: Calendar
    }
    private var key: Key?
    private var cached: [WorkspaceDay] = []

    func days(actions: [Date], captures: [Date], copies: [Date],
              now: Date = Date(), calendar: Calendar = .current) -> [WorkspaceDay] {
        let next = Key(actions: actions, captures: captures, copies: copies,
                       today: calendar.startOfDay(for: now), calendar: calendar)
        if key == next { return cached }
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: next.today) }
        guard let start = days.first else { return [] }
        func bucket(_ dates: [Date]) -> [Date: Int] {
            var counts: [Date: Int] = [:]
            for date in dates where date >= start { counts[calendar.startOfDay(for: date), default: 0] += 1 }
            return counts
        }
        let actions = bucket(actions), captures = bucket(captures), copies = bucket(copies)
        cached = days.map { WorkspaceDay(date: $0, actions: actions[$0] ?? 0,
                                         captures: captures[$0] ?? 0, copies: copies[$0] ?? 0) }
        key = next
        return cached
    }
}
