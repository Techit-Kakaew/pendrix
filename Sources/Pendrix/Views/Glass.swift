import SwiftUI
import AppKit

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Headless ImageRenderer pass: no window, so glass falls back to flat tints.
    var isSnapshot: Bool { get { self[SnapshotKey.self] } set { self[SnapshotKey.self] = newValue } }
}

/// Makes the hosting window a translucent sheet so Liquid Glass has something to refract.
struct WindowGlassTuner: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSView { let v = Tuner(); v.material = material; return v }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Tuner)?.apply() }

    final class Tuner: NSView {
        var material: NSVisualEffectView.Material = .hudWindow
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            func walk(_ v: NSView) {
                if let e = v as? NSVisualEffectView { e.material = material; e.blendingMode = .behindWindow; e.state = .active }
                v.subviews.forEach(walk)
            }
            if let c = window.contentView?.superview { walk(c) } else if let c = window.contentView { walk(c) }
        }
    }
}

/// Card surface. Liquid Glass on macOS 26; thin material + hairline elsewhere; flat tint in snapshots.
struct GlassSurface: ViewModifier {
    var tint: Color? = nil
    var radius: CGFloat = 14
    var interactive = false
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if isSnapshot {
            content.background(shape.fill(.primary.opacity(0.06)))
                .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 1))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                let g: Glass = interactive ? .regular.interactive() : .regular
                content.glassEffect(tint.map { g.tint($0.opacity(0.12)) } ?? g, in: shape)
            } else { legacy(content, shape) }
            #else
            legacy(content, shape)
            #endif
        }
    }

    private func legacy(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content.background(shape.fill(.thinMaterial))
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

extension View {
    func glass(tint: Color? = nil, radius: CGFloat = 14, interactive: Bool = false) -> some View {
        modifier(GlassSurface(tint: tint, radius: radius, interactive: interactive))
    }
}

/// Wraps children so neighbouring glass shapes blend into each other on macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
        #else
        content
        #endif
    }
}

/// Type ramp. One family, rounded digits, restrained weights.
enum Type {
    static let key = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static let title = Font.system(size: 13, weight: .medium)
    static let meta = Font.system(size: 11, weight: .regular)
    static let section = Font.system(size: 11, weight: .semibold)
    static let count = Font.system(size: 22, weight: .medium, design: .rounded)
}

/// ScrollView that degrades to plain layout under ImageRenderer (ScrollView has no intrinsic height there).
struct Scrolling<Content: View>: View {
    var axes: Axis.Set = .vertical
    var indicators = false
    @ViewBuilder var content: Content
    @Environment(\.isSnapshot) private var isSnapshot
    var body: some View {
        if isSnapshot { content } else { ScrollView(axes, showsIndicators: indicators) { content } }
    }
}

/// Window backdrop: heavy blur plus a tint so what's behind reads as colour, not content.
struct WindowBackdrop: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if !isSnapshot {
            ZStack {
                WindowGlassTuner(material: .underWindowBackground)
                Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.55 : 0.45)
            }
            .ignoresSafeArea()
        }
    }
}
