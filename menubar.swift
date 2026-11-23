// Menu bar front end for usage.py.
//
// SwiftBar was the original plan, but 2.1.1 never creates a status item on
// macOS 26 Tahoe - it runs its plugins and then shows nothing - so this owns the
// NSStatusItem directly. All the arithmetic still lives in usage.py; this file
// only shells out to it and draws the JSON.
//
// The panel is an NSPopover with a hand-drawn dark surface rather than an NSMenu,
// because NSMenu gives no control over its background.
//
// Colors follow the dataviz method: the three accents were computed as the
// max-chroma point inside the dark-mode lightness band (OKLCH L 0.48-0.67) for
// their hue family, then validated - lightness, chroma floor, CVD separation,
// normal-vision floor and contrast all pass on this surface. Two consequences
// worth keeping: the bars are ONE hue because they encode one measure (length
// already says "how much"; a second channel would be wasted), and the load state
// always carries a written label, since a status color must never be the only
// signal. The neon glow is drawn as a blurred halo - decoration around a mark,
// never the mark itself.

import AppKit

struct UsageError: Error { let message: String }

// MARK: - theme

enum Theme {
    static let surface      = NSColor(srgbRed: 0.043, green: 0.059, blue: 0.078, alpha: 1)  // #0B0F14
    static let raised       = NSColor(srgbRed: 0.086, green: 0.125, blue: 0.169, alpha: 1)  // #16202B
    static let track        = NSColor(srgbRed: 0.106, green: 0.157, blue: 0.208, alpha: 1)
    static let hairline     = NSColor(srgbRed: 0.129, green: 0.184, blue: 0.239, alpha: 1)

    static let ink          = NSColor(srgbRed: 0.910, green: 0.941, blue: 0.969, alpha: 1)
    static let inkSecondary = NSColor(srgbRed: 0.561, green: 0.639, blue: 0.722, alpha: 1)
    static let inkMuted     = NSColor(srgbRed: 0.361, green: 0.439, blue: 0.522, alpha: 1)

    // Validated marks (see header).
    // Electric blue over cyan: at this lightness the cyan family bottoms out near
    // the chroma floor (C 0.114), while hue 240 reaches C 0.187 - more vivid AND it
    // clears --pairs all against the magenta, which cyan did not (ΔE 2.5 -> 15.6).
    static let electric     = NSColor(srgbRed: 0.000, green: 0.588, blue: 1.000, alpha: 1)  // #0096FF
    static let amber        = NSColor(srgbRed: 0.765, green: 0.494, blue: 0.000, alpha: 1)  // #C37E00
    static let magenta      = NSColor(srgbRed: 0.988, green: 0.000, blue: 0.647, alpha: 1)  // #FC00A5

    // Halo hues only - never used to fill a mark.
    static let electricGlow = NSColor(srgbRed: 0.361, green: 0.757, blue: 1.000, alpha: 1)
    static let amberGlow    = NSColor(srgbRed: 1.000, green: 0.773, blue: 0.239, alpha: 1)
    static let magentaGlow  = NSColor(srgbRed: 1.000, green: 0.239, blue: 0.639, alpha: 1)
}

enum LoadState {
    case normal, elevated, high

    init(_ load: Double?) {
        switch load ?? 0 {
        case ..<0.75: self = .normal
        case ..<1.0:  self = .elevated
        default:      self = .high
        }
    }

    var color: NSColor { switch self { case .normal: .init(Theme.electric); case .elevated: .init(Theme.amber); case .high: .init(Theme.magenta) } }
    var glow: NSColor  { switch self { case .normal: Theme.electricGlow; case .elevated: Theme.amberGlow; case .high: Theme.magentaGlow } }
    /// The written label that keeps the state readable without color.
    var label: String  { switch self { case .normal: "normal"; case .elevated: "elevado"; case .high: "alto" } }
    var glyph: String  { switch self { case .normal: "▽"; case .elevated: "△"; case .high: "▲" } }
}

private extension NSColor {
    convenience init(_ other: NSColor) { self.init(cgColor: other.cgColor)! }
}

// MARK: - model

struct SkillRow {
    let name: String, cost: Double, tokens: Double
}

struct Report {
    var blockCost = 0.0, weekCost = 0.0, reference = 0.0
    var blockBillable = 0.0, blockCache = 0.0, weekBillable = 0.0, weekCache = 0.0
    var load: Double?
    var expiresAt: Double?
    var planMultiple: Double?
    var skills: [SkillRow] = []
    var unattributed: SkillRow?

    init(_ data: [String: Any]) {
        let block = data["block"] as? [String: Any] ?? [:]
        let week = data["week"] as? [String: Any] ?? [:]
        blockCost = block["cost"] as? Double ?? 0
        blockBillable = block["billable"] as? Double ?? 0
        blockCache = block["cache_read"] as? Double ?? 0
        reference = block["reference_p95"] as? Double ?? 0
        load = block["load"] as? Double
        expiresAt = block["expires_at"] as? Double
        weekCost = week["cost"] as? Double ?? 0
        weekBillable = week["billable"] as? Double ?? 0
        weekCache = week["cache_read"] as? Double ?? 0
        planMultiple = week["plan_multiple"] as? Double
        skills = (data["skills"] as? [[String: Any]] ?? []).map {
            SkillRow(name: $0["skill"] as? String ?? "?",
                     cost: $0["cost"] as? Double ?? 0,
                     tokens: $0["tokens"] as? Double ?? 0)
        }
        if let u = data["unattributed"] as? [String: Any] {
            unattributed = SkillRow(name: u["skill"] as? String ?? "",
                                    cost: u["cost"] as? Double ?? 0,
                                    tokens: u["tokens"] as? Double ?? 0)
        }
    }
}

// MARK: - formatting

func money(_ v: Double, decimals: Int = 2) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = decimals
    f.maximumFractionDigits = decimals
    return "$" + (f.string(from: NSNumber(value: v)) ?? "0")
}

func tokens(_ v: Double) -> String {
    switch v {
    case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
    case 1_000_000...:     return String(format: "%.0fM", v / 1_000_000)
    case 1_000...:         return String(format: "%.0fk", v / 1_000)
    default:               return String(format: "%.0f", v)
    }
}

// MARK: - drawing helpers

extension NSView {
    func draw(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular,
              color: NSColor = Theme.ink, tracking: CGFloat = 0, rightAlignedTo: CGFloat? = nil) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        if tracking != 0 { attrs[.kern] = tracking }
        let s = NSAttributedString(string: text, attributes: attrs)
        var origin = point
        if let right = rightAlignedTo { origin.x = right - s.size().width }
        s.draw(at: origin)
    }

    /// A mark plus its halo. The halo is decoration; `fill` is the validated color.
    func glowing(_ path: NSBezierPath, fill: NSColor, glow: NSColor, radius: CGFloat = 10) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = glow.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = .zero
        shadow.set()
        fill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        fill.setFill()
        path.fill()
    }
}

/// A bar that is square where it leaves the baseline and rounded at the data end.
func barPath(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSBezierPath {
    let r = min(4, width / 2, height / 2)
    guard width > r else { return NSBezierPath(rect: NSRect(x: x, y: y, width: max(width, 1), height: height)) }
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x, y: y))
    p.line(to: NSPoint(x: x + width - r, y: y))
    p.appendArc(withCenter: NSPoint(x: x + width - r, y: y + r), radius: r, startAngle: -90, endAngle: 0)
    p.line(to: NSPoint(x: x + width, y: y + height - r))
    p.appendArc(withCenter: NSPoint(x: x + width - r, y: y + height - r), radius: r, startAngle: 0, endAngle: 90)
    p.line(to: NSPoint(x: x, y: y + height))
    p.close()
    return p
}

// MARK: - the panel

final class PanelView: NSView {
    var report: Report? { didSet { needsDisplay = true } }
    var errorMessage: String? { didSet { needsDisplay = true } }

    static let width: CGFloat = 400
    private let pad: CGFloat = 22
    private let rowHeight: CGFloat = 24

    override var isFlipped: Bool { false }

    static let footerHeight: CGFloat = 40

    /// Sum of the vertical steps `draw(_:)` walks, so nothing is clipped when the
    /// skill count changes. Keep in step with the drawing code.
    func fittingHeight() -> CGFloat {
        guard let r = report else { return 200 }
        let header: CGFloat = 34 + 46 + 22 + 16 + 26 + 20 // label, hero, subtitle, note, meter, caption
        let week: CGFloat = 22 + 26 + 18 + 16                  // rule, label, subtitle
        let skillsHeader: CGFloat = 28 + 26 + 6
        let rows = CGFloat(r.skills.count) * rowHeight
        let tail: CGFloat = r.unattributed != nil ? 30 + 24 + 16 : 0
        let bottomPad: CGFloat = 26
        return header + week + skillsHeader + rows + tail + bottomPad + Self.footerHeight
    }

    override func draw(_ dirty: NSRect) {
        Theme.surface.setFill()
        bounds.fill()

        if let errorMessage {
            draw("usage.py falló", at: NSPoint(x: pad, y: bounds.height - 44), size: 14, weight: .semibold, color: Theme.magenta)
            for (i, line) in errorMessage.split(separator: "\n").suffix(5).enumerated() {
                draw(String(line), at: NSPoint(x: pad, y: bounds.height - 70 - CGFloat(i) * 16), size: 10, color: Theme.inkSecondary)
            }
            return
        }
        guard let r = report else { return }

        var y = bounds.height - 34
        let state = LoadState(r.load)

        // ---- hero: the block, with the load dial on the right -------------
        draw("BLOQUE DE 5 H", at: NSPoint(x: pad, y: y), size: 10, weight: .semibold,
             color: Theme.inkMuted, tracking: 1.4)
        y -= 46
        // "≈" up front: this is what the tokens would cost at API list price, not a
        // charge. The plan is a flat subscription and bills nothing per token.
        draw("≈" + money(r.blockCost, decimals: 0), at: NSPoint(x: pad, y: y), size: 42, weight: .bold, color: Theme.ink)

        let dial = NSRect(x: bounds.width - pad - 76, y: y - 6, width: 76, height: 76)
        drawDial(in: dial, load: r.load, state: state)

        y -= 22
        draw("\(tokens(r.blockBillable)) facturables · \(tokens(r.blockCache)) de caché",
             at: NSPoint(x: pad, y: y), size: 11, color: Theme.inkSecondary)
        y -= 16
        draw("equivalente a precio de API — tu plan es fijo, no cobra por token",
             at: NSPoint(x: pad, y: y), size: 10, color: Theme.inkMuted)

        // ---- meter: this block against a heavy one ------------------------
        y -= 26
        let meterWidth = bounds.width - pad * 2 - 96
        drawMeter(x: pad, y: y, width: meterWidth, load: r.load, state: state)

        y -= 20
        var caption = "p95 \(money(r.reference, decimals: 0))"
        if let expires = r.expiresAt {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            caption += " · libera \(f.string(from: Date(timeIntervalSince1970: expires)))"
        }
        draw(caption, at: NSPoint(x: pad, y: y), size: 10, color: Theme.inkMuted)

        // ---- week ---------------------------------------------------------
        y -= 22
        hairline(at: y)
        y -= 26
        draw("ÚLTIMOS 7 DÍAS", at: NSPoint(x: pad, y: y), size: 10, weight: .semibold,
             color: Theme.inkMuted, tracking: 1.4)
        draw("≈" + money(r.weekCost), at: NSPoint(x: 0, y: y - 4), size: 17, weight: .semibold,
             color: Theme.ink, rightAlignedTo: bounds.width - pad)
        y -= 18
        draw("\(tokens(r.weekBillable)) facturables · \(tokens(r.weekCache)) de caché",
             at: NSPoint(x: pad, y: y), size: 11, color: Theme.inkSecondary)
        y -= 16
        if let mult = r.planMultiple {
            draw(String(format: "×%.0f de lo que cuesta el plan en 7 días", mult),
                 at: NSPoint(x: pad, y: y), size: 10, color: Theme.inkMuted)
        }

        // ---- ranked skills -------------------------------------------------
        y -= 28
        hairline(at: y)
        y -= 26
        draw("PESO POR SKILL", at: NSPoint(x: pad, y: y), size: 10, weight: .semibold,
             color: Theme.inkMuted, tracking: 1.4)

        // Scaled to the largest SKILL, not to (sin skill): that row is an order of
        // magnitude bigger and is not a skill, so it gets a figure, not a bar.
        let peak = r.skills.map(\.cost).max() ?? 1
        let labelWidth: CGFloat = 184
        let valueWidth: CGFloat = 56
        let barMax = bounds.width - pad * 2 - labelWidth - valueWidth - 16

        y -= 6
        for skill in r.skills {
            y -= rowHeight
            let name = skill.name.count > 29 ? String(skill.name.prefix(28)) + "…" : skill.name
            draw(name, at: NSPoint(x: pad, y: y + 5), size: 11, color: Theme.ink)

            let trackRect = NSRect(x: pad + labelWidth, y: y + 7, width: barMax, height: 9)
            Theme.track.setFill()
            barPath(x: trackRect.minX, y: trackRect.minY, width: trackRect.width, height: trackRect.height).fill()

            let w = max(2, barMax * CGFloat(skill.cost / max(peak, 0.0001)))
            glowing(barPath(x: trackRect.minX, y: trackRect.minY, width: w, height: trackRect.height),
                    fill: Theme.electric, glow: Theme.electricGlow, radius: 7)

            draw(money(skill.cost), at: NSPoint(x: 0, y: y + 5), size: 11,
                 color: Theme.inkSecondary, rightAlignedTo: bounds.width - pad)
        }

        // ---- outside any skill ---------------------------------------------
        if let u = r.unattributed {
            y -= 30
            hairline(at: y)
            y -= 24
            draw("Fuera de toda skill", at: NSPoint(x: pad, y: y), size: 11, color: Theme.inkSecondary)
            draw(money(u.cost), at: NSPoint(x: 0, y: y), size: 11, weight: .semibold,
                 color: Theme.ink, rightAlignedTo: bounds.width - pad)
            y -= 16
            let share = r.weekCost > 0 ? u.cost / r.weekCost : 0
            draw(String(format: "%.0f%% de la semana", share * 100),
                 at: NSPoint(x: pad, y: y), size: 10, color: Theme.inkMuted)
        }
    }

    private func hairline(at y: CGFloat) {
        Theme.hairline.setFill()
        NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: 1).fill()
    }

    /// Ring dial: track plus an arc for the load, with the number and the written
    /// state inside. Never color-only - the label and glyph carry the state too.
    private func drawDial(in rect: NSRect, load: Double?, state: LoadState) {
        let center = NSPoint(x: rect.midX, y: rect.midY + 6)
        let radius: CGFloat = 26
        let lineWidth: CGFloat = 7

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 215, endAngle: -35, clockwise: true)
        track.lineWidth = lineWidth
        track.lineCapStyle = .round
        Theme.track.setStroke()
        track.stroke()

        if let load {
            let sweep = min(1, max(0, load)) * 250
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 215, endAngle: 215 - sweep, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = state.glow.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 9
            shadow.shadowOffset = .zero
            shadow.set()
            state.color.setStroke()
            arc.stroke()
            NSGraphicsContext.restoreGraphicsState()
            state.color.setStroke()
            arc.stroke()

            let pct = String(format: "%.0f%%", load * 100)
            let w = NSAttributedString(string: pct, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)]).size().width
            draw(pct, at: NSPoint(x: center.x - w / 2, y: center.y - 4), size: 15, weight: .semibold, color: Theme.ink)
        }

        let text = "\(state.glyph) \(state.label)"
        let w = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)]).size().width
        draw(text, at: NSPoint(x: center.x - w / 2, y: rect.minY - 6), size: 10, weight: .medium, color: state.color)
    }

    private func drawMeter(x: CGFloat, y: CGFloat, width: CGFloat, load: Double?, state: LoadState) {
        let height: CGFloat = 6
        Theme.track.setFill()
        barPath(x: x, y: y, width: width, height: height).fill()
        guard let load else { return }
        let w = max(3, width * CGFloat(min(1, load)))
        glowing(barPath(x: x, y: y, width: w, height: height), fill: state.color, glow: state.glow, radius: 8)

        // The 100% mark, so "over a heavy block" is visible and not just implied.
        if load > 1 {
            Theme.ink.withAlphaComponent(0.35).setFill()
            NSRect(x: x + width - 1, y: y - 3, width: 1, height: height + 6).fill()
        }
    }
}

// MARK: - footer buttons

final class FooterButton: NSButton {
    override func draw(_ dirty: NSRect) {
        let hovered = isHighlighted
        if hovered {
            Theme.raised.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        let s = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: hovered ? Theme.ink : Theme.inkSecondary,
        ])
        s.draw(at: NSPoint(x: bounds.midX - s.size().width / 2, y: bounds.midY - s.size().height / 2))
    }
}

/// Panel plus footer. One type, so the offscreen `--render` preview and the live
/// popover cannot drift apart.
final class PanelContainer: NSView {
    let panel = PanelView()
    let refreshButton = FooterButton(title: "Refrescar", target: nil, action: nil)
    let quitButton = FooterButton(title: "Salir", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        for b in [refreshButton, quitButton] {
            b.isBordered = false
            b.wantsLayer = true
            addSubview(b)
        }
        addSubview(panel)
    }

    required init?(coder: NSCoder) { nil }

    /// Returns the height the whole thing wants.
    @discardableResult
    func layoutContents() -> CGFloat {
        let height = panel.fittingHeight()
        frame = NSRect(x: 0, y: 0, width: PanelView.width, height: height)
        panel.frame = NSRect(x: 0, y: PanelView.footerHeight,
                             width: PanelView.width, height: height - PanelView.footerHeight)
        refreshButton.frame = NSRect(x: 14, y: 8, width: 92, height: 26)
        quitButton.frame = NSRect(x: PanelView.width - 14 - 64, y: 8, width: 64, height: 26)
        return height
    }

    override func draw(_ dirty: NSRect) {
        Theme.surface.setFill()
        bounds.fill()
        // Rule above the footer, so the actions read as a separate strip.
        Theme.hairline.setFill()
        NSRect(x: 0, y: PanelView.footerHeight, width: bounds.width, height: 1).fill()
    }
}

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let container = PanelContainer(frame: NSRect(x: 0, y: 0, width: PanelView.width, height: 420))
    private let usageScript: String
    private var timer: Timer?
    private var lastState = LoadState.normal

    init(usageScript: String) { self.usageScript = usageScript }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.title = "…"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = container
        container.refreshButton.target = self
        container.refreshButton.action = #selector(refresh)
        container.quitButton.target = NSApp
        container.quitButton.action = #selector(NSApplication.terminate(_:))

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func layout() {
        popover.contentSize = NSSize(width: PanelView.width, height: container.layoutContents())
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refresh()
            layout()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }

    // MARK: data

    private func runUsageScript() -> Result<[String: Any], UsageError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", usageScript]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return .failure(UsageError(message: "no se pudo ejecutar python3: \(error.localizedDescription)"))
        }
        // Read before waiting: a full pipe buffer would deadlock the child.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8) ?? ""
            return .failure(UsageError(message: message.isEmpty ? "usage.py salió con \(process.terminationStatus)" : message))
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            return .failure(UsageError(message: "usage.py no devolvió JSON"))
        }
        return .success(parsed)
    }

    @objc func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.runUsageScript()
            DispatchQueue.main.async {
                switch result {
                case .failure(let failure):
                    self.container.panel.errorMessage = failure.message
                    self.container.panel.report = nil
                    self.statusItem.button?.title = "⚠︎"
                case .success(let data):
                    let report = Report(data)
                    self.container.panel.errorMessage = nil
                    self.container.panel.report = report
                    self.updateTitle(report)
                }
                self.layout()
            }
        }
    }

    private func updateTitle(_ report: Report) {
        let state = LoadState(report.load)
        lastState = state
        let text = NSMutableAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: state.color,
            .baselineOffset: 1,
        ])
        text.append(NSAttributedString(string: money(report.blockCost, decimals: 0), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ]))
        statusItem.button?.attributedTitle = text
    }
}

func renderPanel(to path: String, usageScript: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", usageScript]
    let out = Pipe()
    process.standardOutput = out
    try? process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        FileHandle.standardError.write("usage.py no devolvió JSON\n".data(using: .utf8)!)
        return
    }

    let container = PanelContainer(frame: NSRect(x: 0, y: 0, width: PanelView.width, height: 420))
    container.panel.report = Report(parsed)
    container.layoutContents()
    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
    container.cacheDisplay(in: container.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("escrito: \(path)  \(Int(container.bounds.width))x\(Int(container.bounds.height))")
    }
}

@main
enum ClaudeUsageBar {
    // NSApplication.delegate is a WEAK reference. Held only by a local, the
    // delegate is released right after assignment under -O, taking the status
    // item with it: the app keeps running and polling, but the menu bar is empty.
    static var retainedDelegate: AppDelegate?

    static func main() {
        // `--render out.png` draws the panel offscreen with real data, so the
        // layout can be inspected without clicking the status item.
        let args = Array(CommandLine.arguments.dropFirst())
        var renderTo: String?
        var script = Bundle.main.bundlePath + "/Contents/Resources/usage.py"
        var i = 0
        while i < args.count {
            if args[i] == "--render", i + 1 < args.count {
                renderTo = args[i + 1]
                i += 2
            } else {
                script = args[i]        // an explicit path to usage.py
                i += 1
            }
        }

        let app = NSApplication.shared

        if let renderTo {
            renderPanel(to: renderTo, usageScript: script)
            return
        }

        let delegate = AppDelegate(usageScript: script)
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        app.run()
    }
}
