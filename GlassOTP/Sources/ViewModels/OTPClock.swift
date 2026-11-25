import Foundation
import Observation

@MainActor
@Observable
final class OTPClock {
    private(set) var now: Date = Date()
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init() {
        setActive(true)
    }

    func setActive(_ isActive: Bool) {
        if isActive {
            now = Date()
            guard tickTask == nil else { return }
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    let current = Date().timeIntervalSince1970
                    let delay = max(0.05, 1.0 - (current - floor(current)) + 0.015)
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self else { break }
                    self.now = Date()
                }
            }
        } else {
            tickTask?.cancel()
            tickTask = nil
        }
    }
}
