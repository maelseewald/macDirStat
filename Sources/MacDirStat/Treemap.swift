import AppKit

/// Global lock: held by the background treemap renderer while it reads the tree,
/// and by the main thread while it mutates the tree (e.g. after moving something to the Trash).
let treeLock = NSLock()

struct RGB {
    var r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
}

struct TRect {
    var x: Double, y: Double, w: Double, h: Double
    init(_ x: Double = 0, _ y: Double = 0, _ w: Double = 0, _ h: Double = 0) { self.x = x; self.y = y; self.w = w; self.h = h }
    func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px < x + w && py >= y && py < y + h }
}

// MARK: - Layout (squarified treemap, deterministic so hit-testing matches rendering)

enum TreemapLayout {
    /// Folders smaller than this (in pixels) are drawn as one block.
    static let minSplit: Double = 2.0

    static func visibleChildren(_ n: Node) -> ArraySlice<Node> {
        let c = n.children
        var end = c.count
        while end > 0 && c[end - 1].size <= 0 { end -= 1 }
        return c[0..<end]
    }

    static func shouldSplit(_ n: Node, _ r: TRect) -> Bool {
        n.isDirectory && r.w >= minSplit && r.h >= minSplit && n.children.first.map { $0.size > 0 } == true
    }

    static func squarify(_ nodes: ArraySlice<Node>, in rect: TRect) -> [TRect] {
        let count = nodes.count
        var result = [TRect](repeating: TRect(), count: count)
        guard count > 0, rect.w > 0, rect.h > 0 else { return result }
        var sizes = [Double](repeating: 0, count: count)
        var total = 0.0
        var k = 0
        for n in nodes { sizes[k] = Double(n.size); total += sizes[k]; k += 1 }
        guard total > 0 else { return result }
        let scale = rect.w * rect.h / total
        for i in 0..<count { sizes[i] *= scale }

        var r = rect
        var start = 0
        while start < count {
            let shortSide = max(min(r.w, r.h), 1e-9)
            let w2 = shortSide * shortSide
            var end = start
            var rowSum = 0.0, rowMin = Double.infinity, rowMax = 0.0
            var worst = Double.infinity
            while end < count {
                let a = sizes[end]
                let nSum = rowSum + a
                let nMin = min(rowMin, a), nMax = max(rowMax, a)
                let s2 = nSum * nSum
                let nWorst = max(w2 * nMax / s2, s2 / (w2 * nMin))
                if end > start && nWorst > worst { break }
                rowSum = nSum; rowMin = nMin; rowMax = nMax; worst = nWorst
                end += 1
            }
            let isLast = (end == count)
            if r.w >= r.h {
                // Column on the left side
                var colW = isLast ? r.w : (r.h > 0 ? rowSum / r.h : 0)
                if colW > r.w { colW = r.w }
                var y = r.y
                for i in start..<end {
                    var h = colW > 0 ? sizes[i] / colW : 0
                    if i == end - 1 { h = r.y + r.h - y }
                    result[i] = TRect(r.x, y, colW, max(h, 0))
                    y += h
                }
                r.x += colW; r.w -= colW
            } else {
                // Row along the top
                var rowH = isLast ? r.h : (r.w > 0 ? rowSum / r.w : 0)
                if rowH > r.h { rowH = r.h }
                var x = r.x
                for i in start..<end {
                    var w = rowH > 0 ? sizes[i] / rowH : 0
                    if i == end - 1 { w = r.x + r.w - x }
                    result[i] = TRect(x, r.y, max(w, 0), rowH)
                    x += w
                }
                r.y += rowH; r.h -= rowH
            }
            start = end
        }
        return result
    }

    /// The deepest drawn node at a point (pixel coordinates).
    static func hitTest(root: Node, bounds: TRect, x: Double, y: Double) -> Node? {
        guard bounds.contains(x, y), root.size > 0 else { return root.size > 0 ? nil : root }
        var node = root
        var rect = bounds
        while shouldSplit(node, rect) {
            let kids = visibleChildren(node)
            let rects = squarify(kids, in: rect)
            var found = false
            for (i, child) in kids.enumerated() where rects[i].contains(x, y) {
                node = child; rect = rects[i]; found = true
                break
            }
            if !found { break }
        }
        return node
    }

    /// Where `target` is drawn (pixel coordinates), or nil if it isn't visible under `root`.
    static func rect(of target: Node, root: Node, bounds: TRect) -> TRect? {
        guard root.contains(target) else { return nil }
        var chain: [Node] = []
        var n: Node? = target
        while let c = n, c !== root { chain.append(c); n = c.parent }
        var rect = bounds
        var current = root
        for next in chain.reversed() {
            guard shouldSplit(current, rect), next.size > 0 else { return rect } // drawn as part of `current`
            let kids = visibleChildren(current)
            guard let idx = kids.firstIndex(where: { $0 === next }) else { return nil }
            let rects = squarify(kids, in: rect)
            rect = rects[idx - kids.startIndex]
            current = next
        }
        return rect
    }
}

// MARK: - Cushion renderer (van Wijk / WinDirStat style shading)

final class TreemapRenderer {
    private let w: Int, h: Int
    private let colors: [RGB]
    private let highlight: Int32
    private var px: UnsafeMutablePointer<UInt8>

    private static let heightFactor = 0.38
    private static let scaleFactor = 0.91
    private static let ambient = 0.2
    private static let brightness = 1.25
    private static let light: (Double, Double, Double) = {
        let (x, y, z) = (-1.0, -1.0, 10.0)
        let len = (x * x + y * y + z * z).squareRoot()
        return (x / len, y / len, z / len)
    }()
    static let otherColor = RGB(165, 165, 165)

    init(width: Int, height: Int, colors: [RGB], highlight: Int32) {
        w = width; h = height
        self.colors = colors
        self.highlight = highlight
        px = .allocate(capacity: max(1, width * height * 4))
    }

    deinit { px.deallocate() }

    func render(root: Node) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        // background
        for i in 0..<(w * h) {
            px[i * 4] = 40; px[i * 4 + 1] = 40; px[i * 4 + 2] = 40; px[i * 4 + 3] = 255
        }
        if root.size > 0 {
            draw(root, TRect(0, 0, Double(w), Double(h)), (0, 0, 0, 0), TreemapRenderer.heightFactor)
        }
        let data = Data(bytes: px, count: w * h * 4) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func color(for ext: Int32) -> RGB {
        var c = (ext >= 0 && Int(ext) < colors.count) ? colors[Int(ext)] : TreemapRenderer.otherColor
        if highlight >= 0 && ext != highlight {
            let g = (c.r + c.g + c.b) / 3 * 0.35
            c = RGB(g, g, g)
        }
        return c
    }

    private typealias Surface = (Double, Double, Double, Double)

    private func draw(_ node: Node, _ r: TRect, _ parentSurface: Surface, _ height: Double) {
        var s = parentSurface
        if r.w > 0 {
            let x1 = r.x, x2 = r.x + r.w
            s.2 += 4 * height * (x2 + x1) / (x2 - x1)
            s.0 -= 4 * height / (x2 - x1)
        }
        if r.h > 0 {
            let y1 = r.y, y2 = r.y + r.h
            s.3 += 4 * height * (y2 + y1) / (y2 - y1)
            s.1 -= 4 * height / (y2 - y1)
        }

        if node.isDirectory {
            if TreemapLayout.shouldSplit(node, r) {
                let kids = TreemapLayout.visibleChildren(node)
                let rects = TreemapLayout.squarify(kids, in: r)
                let childHeight = height * TreemapRenderer.scaleFactor
                for (i, child) in kids.enumerated() {
                    let cr = rects[i]
                    // skip rectangles that cover no pixel at all
                    if (cr.x + cr.w).rounded() <= cr.x.rounded() || (cr.y + cr.h).rounded() <= cr.y.rounded() { continue }
                    draw(child, cr, s, childHeight)
                }
            } else {
                paint(r, s, color(for: node.dominantExt))
            }
        } else {
            paint(r, s, color(for: node.ext))
        }
    }

    private func paint(_ r: TRect, _ s: Surface, _ c: RGB) {
        let x0 = max(0, min(w, Int(r.x.rounded())))
        let x1 = max(0, min(w, Int((r.x + r.w).rounded())))
        let y0 = max(0, min(h, Int(r.y.rounded())))
        let y1 = max(0, min(h, Int((r.y + r.h).rounded())))
        guard x1 > x0, y1 > y0 else { return }
        let (lx, ly, lz) = TreemapRenderer.light
        let ia = TreemapRenderer.ambient, isrc = 1 - ia, br = TreemapRenderer.brightness
        for iy in y0..<y1 {
            let ny = -(2 * s.1 * (Double(iy) + 0.5) + s.3)
            var o = (iy * w + x0) * 4
            for ix in x0..<x1 {
                let nx = -(2 * s.0 * (Double(ix) + 0.5) + s.2)
                var cosa = (nx * lx + ny * ly + lz) / (nx * nx + ny * ny + 1).squareRoot()
                if cosa < 0 { cosa = 0 }
                let f = (ia + isrc * cosa) * br
                px[o]     = UInt8(max(0, min(255, c.r * f)))
                px[o + 1] = UInt8(max(0, min(255, c.g * f)))
                px[o + 2] = UInt8(max(0, min(255, c.b * f)))
                px[o + 3] = 255
                o += 4
            }
        }
    }
}

// MARK: - View

final class TreemapView: NSView {
    var onSelect: ((Node) -> Void)?
    var onHover: ((Node?) -> Void)?
    var onDoubleClick: ((Node) -> Void)?
    var menuProvider: ((Node) -> NSMenu?)?

    private(set) var root: Node?
    private var selected: Node?
    private var colors: [RGB] = []
    private var highlight: Int32 = -1
    private var version = -1

    private var image: CGImage?
    private var renderGeneration = 0
    private var pendingRender: DispatchWorkItem?
    private let renderQueue = DispatchQueue(label: "macdirstat.treemap", qos: .userInitiated)
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(root: Node?, colors: [RGB], highlight: Int32, version: Int, selected: Node?) {
        let needsRender = root !== self.root || highlight != self.highlight || version != self.version || colors.count != self.colors.count
        self.root = root
        self.colors = colors
        self.highlight = highlight
        self.version = version
        if selected !== self.selected {
            self.selected = selected
            needsDisplay = true
        }
        if needsRender {
            if root == nil { image = nil; needsDisplay = true }
            scheduleRender(delay: 0)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleRender(delay: 0.12)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleRender(delay: 0)
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private var pixelBounds: TRect {
        TRect(0, 0, Double(Int(bounds.width * scale)), Double(Int(bounds.height * scale)))
    }

    private func scheduleRender(delay: TimeInterval) {
        pendingRender?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startRender() }
        pendingRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startRender() {
        renderGeneration += 1
        let gen = renderGeneration
        guard let root, bounds.width >= 1, bounds.height >= 1 else { return }
        let pb = pixelBounds
        let pw = min(Int(pb.w), 8192), ph = min(Int(pb.h), 8192)
        let colors = self.colors, hl = self.highlight
        renderQueue.async { [weak self] in
            // A newer render was requested meanwhile? Skip this one.
            var stale = false
            DispatchQueue.main.sync { stale = (self?.renderGeneration ?? gen) != gen }
            if stale { return }
            treeLock.lock()
            let img = TreemapRenderer(width: pw, height: ph, colors: colors, highlight: hl).render(root: root)
            treeLock.unlock()
            DispatchQueue.main.async {
                guard let self, gen == self.renderGeneration else { return }
                self.image = img
                self.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.16, alpha: 1).setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let image {
            ctx.saveGState()
            ctx.interpolationQuality = .low
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        } else if root != nil {
            let s = "Drawing…" as NSString
            s.draw(at: NSPoint(x: 12, y: 12), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13)])
        }
        if let sel = selected, let root, let r = TreemapLayout.rect(of: sel, root: root, bounds: pixelBounds) {
            let s = Double(scale)
            let rect = NSRect(x: r.x / s, y: r.y / s, width: r.w / s, height: r.h / s).insetBy(dx: 1, dy: 1)
            let outer = NSBezierPath(rect: rect)
            outer.lineWidth = 3
            NSColor.black.withAlphaComponent(0.8).setStroke()
            outer.stroke()
            let inner = NSBezierPath(rect: rect)
            inner.lineWidth = 1.5
            NSColor.white.setStroke()
            inner.stroke()
        }
    }

    private func node(at event: NSEvent) -> Node? {
        guard let root else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let s = Double(scale)
        return TreemapLayout.hitTest(root: root, bounds: pixelBounds, x: Double(p.x) * s, y: Double(p.y) * s)
    }

    override func mouseDown(with event: NSEvent) {
        guard let n = node(at: event) else { return }
        if event.clickCount == 2 { onDoubleClick?(n) } else { onSelect?(n) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let n = node(at: event) else { return nil }
        onSelect?(n)
        return menuProvider?(n)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) { onHover?(node(at: event)) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
}
