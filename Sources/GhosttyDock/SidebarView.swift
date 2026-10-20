import SwiftUI
import DockCore

/// Catppuccin Mocha, to sit next to the Ghostty theme in use. All text is
/// Palette.text or a status colour, never grey: grey on mantle is hard to read.
/// Every status has its own hue, used for both its dot and its label.
enum Palette {
    static let base = Color(red: 0.118, green: 0.118, blue: 0.180)      // #1e1e2e
    static let mantle = Color(red: 0.094, green: 0.094, blue: 0.145)    // #181825
    static let surface = Color(red: 0.192, green: 0.196, blue: 0.267)   // #313244
    static let text = Color(red: 0.804, green: 0.839, blue: 0.957)      // #cdd6f4
    static let green = Color(red: 0.651, green: 0.890, blue: 0.631)     // #a6e3a1
    static let peach = Color(red: 0.980, green: 0.702, blue: 0.529)     // #fab387
    static let blue = Color(red: 0.537, green: 0.706, blue: 0.980)      // #89b4fa
    static let mauve = Color(red: 0.796, green: 0.651, blue: 0.969)     // #cba6f7
    static let teal = Color(red: 0.580, green: 0.886, blue: 0.835)      // #94e2d5
    static let pink = Color(red: 0.961, green: 0.761, blue: 0.906)      // #f5c2e7

    static func color(_ s: DisplayStatus) -> Color {
        switch s {
        case .running: return green
        case .waiting: return peach
        case .unread: return blue
        case .inactive: return mauve
        case .shell: return teal
        case .unknown: return pink
        }
    }

    static func label(_ s: DisplayStatus) -> String {
        switch s {
        case .running: return "Running"
        case .waiting: return "Needs you"
        case .unread: return "Finished"
        case .inactive: return "Idle"
        case .shell: return "Shell"
        case .unknown: return "No activity yet"
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: DockModel
    var trusted: Bool
    var onTrust: () -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.rows) { row in
                        RowView(row: row).onTapGesture { model.select(row) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            if !trusted { trustHint }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.mantle)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Sessions").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.text)
            if model.waitingCount > 0 { Badge(count: model.waitingCount, color: Palette.peach) }
            if model.unreadCount > 0 { Badge(count: model.unreadCount, color: Palette.blue) }
            Spacer()
            Button(action: model.newSession) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.text)
            .help("Start Claude Code in a folder, as a new tab")
            Menu {
                Button("Settings…", action: onSettings)
                Button("Quit Ghostty Dock", action: onQuit)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Palette.text)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var trustHint: some View {
        Button(action: onTrust) {
            Text("Allow Accessibility so the sidebar can move Ghostty aside instead of covering it")
                .font(.system(size: 10))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .padding(10)
    }
}

struct Badge: View {
    var count: Int
    var color: Color

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Palette.base)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color))
    }
}

struct RowView: View {
    var row: Row
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            StatusDot(status: row.status).id(row.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 13, weight: row.selected ? .semibold : .regular))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(subtitle(now: ctx.date))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.color(row.status))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(row.selected ? Palette.surface : hover ? Palette.base : Color.clear)
        )
        .overlay(alignment: .leading) {
            if row.selected {
                RoundedRectangle(cornerRadius: 1.5).fill(Palette.blue).frame(width: 3, height: 18).offset(x: -3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(row.detail.isEmpty ? row.name : row.detail)
    }

    private func subtitle(now: Date) -> String {
        let label = Palette.label(row.status)
        guard let since = row.since else { return label }
        return label + " · " + elapsed(now.timeIntervalSince(since))
    }

    private func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}

struct StatusDot: View {
    var status: DisplayStatus
    @State private var pulse = false

    var body: some View {
        ZStack {
            if status == .waiting {
                Circle()
                    .fill(Palette.peach.opacity(0.35))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.0 : 0.5)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
            }
            if status == .shell || status == .unknown {
                Circle().strokeBorder(Palette.color(status), lineWidth: 1.5).frame(width: 9, height: 9)
            } else {
                Circle().fill(Palette.color(status)).frame(width: 9, height: 9)
            }
        }
        .frame(width: 16, height: 16)
        .onAppear { pulse = true }
        .accessibilityLabel(Palette.label(status))
    }
}
