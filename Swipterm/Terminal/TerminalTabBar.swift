import SwiftUI

struct TerminalTabBar: View {
    let sessions: [TerminalSession]
    let activeSessionID: UUID?
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(sessions) { session in
                        TerminalTabItem(
                            session: session,
                            isSelected: session.id == activeSessionID,
                            onSelect: { onSelect(session.id) },
                            onClose: { onClose(session.id) }
                        )
                        .id(session.id)
                    }
                }
                .padding(3)
            }
            .scrollIndicators(.hidden)
            .onChange(of: activeSessionID) { _, newID in
                guard let newID else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .modifier(TabBarChromeModifier())
    }
}

private struct TerminalTabItem: View {
    let session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    Text(session.title)
                        .font(.subheadline.weight(isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.vertical, 5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel(Text("Close Session"))
        }
        .frame(minWidth: 112, maxWidth: 220)
        .background {
            if isSelected {
                Capsule()
                    .fill(Color.primary.opacity(0.11))
            }
        }
        .contextMenu {
            Button("Close Session", systemImage: "xmark", role: .destructive, action: onClose)
        }
    }
}

private struct TabBarChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        }
    }
}
