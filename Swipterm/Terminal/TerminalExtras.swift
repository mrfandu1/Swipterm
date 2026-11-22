import Foundation
import GhosttyTerminal
import Observation

@Observable
final class TerminalExtras: NSObject,
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceColorChangeDelegate,
    TerminalSurfaceOpenURLDelegate
{
    @ObservationIgnored weak var state: TerminalViewState?
    @ObservationIgnored var onCommandKey: ((String) -> Bool)?
    @ObservationIgnored var alwaysShowsSymbolBar = false
    @ObservationIgnored var onOpenURL: ((String, TerminalOpenURLKind) -> Void)?
    @ObservationIgnored var onDesktopNotification: ((String, String) -> Void)?

    var title: String = ""
    var workingDirectory: String = ""

    func terminalDidChangeTitle(_ title: String) {
        state?.terminalDidChangeTitle(title)
        self.title = title
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        state?.terminalDidResize(size)
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        state?.terminalDidChangeFocus(focused)
    }

    func terminalDidClose(processAlive: Bool) {
        state?.terminalDidClose(processAlive: processAlive)
    }

    func terminalDidRingBell() {
        state?.terminalDidRingBell()
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        state?.terminalDidRequestDesktopNotification(title: title, body: body)
        onDesktopNotification?(title, body)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        state?.terminalDidChangeWorkingDirectory(path)
        workingDirectory = path
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        state?.terminalDidFinishCommand(exitCode: exitCode, durationNanos: durationNanos)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        state?.terminalDidAttachSurface(surface)
    }

    func terminalDidDetachSurface() {
        state?.terminalDidDetachSurface()
    }

    func terminalDidChangeColor(_ change: TerminalColorChange) {
        state?.terminalDidChangeColor(change)
    }

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        onOpenURL?(url, kind)
    }
}
