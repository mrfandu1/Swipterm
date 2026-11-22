import Foundation
import Observation

@Observable
final class TerminalSessionManager {
    private(set) var sessions: [TerminalSession] = [] {
        didSet { recomputeActiveSession() }
    }

    var activeSessionID: UUID? {
        didSet { recomputeActiveSession() }
    }

    private(set) var activeSession: TerminalSession?

    func ensureInitialSession() {
        if sessions.isEmpty {
            addSession()
        } else if activeSessionID == nil {
            activeSessionID = sessions.first?.id
        }
    }

    func addSession() {
        let numbers = Set(sessions.map(\.number))
        let session = TerminalSession(number: (1...).first { !numbers.contains($0) }!)
        let id = session.id
        session.onCleanExit = { [weak self] in
            Task {
                try? await Task.sleep(for: .seconds(1))
                self?.closeSession(id: id)
            }
        }
        sessions.append(session)
        activeSessionID = id
        session.beginStart()
    }

    func selectSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        activeSessionID = sessions[index].id
    }

    func selectAdjacentSession(offset: Int) {
        guard sessions.count > 1,
              let currentID = activeSessionID,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentID })
        else { return }
        let nextIndex = (currentIndex + offset + sessions.count) % sessions.count
        activeSessionID = sessions[nextIndex].id
    }

    func closeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index).close()
        if sessions.isEmpty {
            addSession()
        } else if activeSessionID == id {
            activeSessionID = sessions[min(index, sessions.count - 1)].id
        }
    }

    func closeAll() {
        for session in sessions {
            session.close()
        }
        sessions.removeAll()
        activeSessionID = nil
    }

    private func recomputeActiveSession() {
        activeSession = sessions.first { $0.id == activeSessionID }
    }
}
