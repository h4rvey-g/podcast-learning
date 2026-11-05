import Foundation

public struct ImportProgress: Sendable {
    public struct Step: Identifiable, Sendable {
        public enum State: Sendable { case waiting, running, done, failed }
        public let id: String
        public let title: String
        public let state: State
        public let fraction: Double?
        public init(_ id: String, _ title: String, _ state: State, fraction: Double? = nil) {
            self.id = id; self.title = title; self.state = state
            self.fraction = fraction.map { $0.isFinite ? max(0, min(1, $0)) : 0 }
        }
    }
    public let steps: [Step]
    public init(steps: [Step]) { self.steps = steps }
    public var completed: Int { steps.filter { $0.state == .done }.count }
    /// Completion of work steps, not an estimate of elapsed or remaining time.
    public var fraction: Double {
        guard !steps.isEmpty else { return 0 }
        return steps.reduce(0) { $0 + ($1.state == .done ? 1 : $1.state == .running ? $1.fraction ?? 0 : 0) } / Double(steps.count)
    }
    public var title: String {
        let active = steps.filter { $0.state == .running || $0.state == .failed }
        return (active.isEmpty ? steps.filter { $0.state == .waiting }.prefix(1).map(\.title) : active.map(\.title)).joined(separator: " · ")
    }
}
