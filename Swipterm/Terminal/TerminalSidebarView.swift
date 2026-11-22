import SwiftUI

struct TerminalSidebarView: View {
    let sessionManager: TerminalSessionManager
    let onSelectSession: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(sessionManager.sessions) { session in
                    TerminalSidebarRow(
                        session: session,
                        isSelected: session.id == sessionManager.activeSessionID,
                        onSelect: {
                            sessionManager.activeSessionID = session.id
                            onSelectSession()
                        },
                        onClose: {
                            sessionManager.closeSession(id: session.id)
                        }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button(action: onOpenSettings) {
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape")
                            .font(.body.weight(.medium))
                        Text("Settings")
                            .font(.body)
                        Spacer()
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(Text(verbatim: "Swipterm"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sessionManager.addSession()
                    onSelectSession()
                } label: {
                    Label("New Session", systemImage: "plus")
                }
            }
        }
    }
}

private struct TerminalSidebarRow: View {
    let session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    Text(session.title)
                        .font(.body.weight(isSelected ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel(Text("Close Session"))
        }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.11))
            }
        }
        .contextMenu {
            Button("Close Session", systemImage: "xmark", role: .destructive, action: onClose)
        }
    }
}
