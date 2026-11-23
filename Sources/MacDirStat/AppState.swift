import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()
    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
    static func size(_ b: Int64) -> String { byteFormatter.string(fromByteCount: b) }
    static func count(_ n: Int64) -> String { numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)" }
    static func date(_ d: Date?) -> String { d.map { dateFormatter.string(from: $0) } ?? "" }
}

struct ExtStat: Identifiable {
    let id: Int32
    let name: String
    let description: String
    let bytes: Int64
    let count: Int64
    let color: Color
}

struct VolumeInfo: Identifiable {
    let id: String   // mount path
    let name: String
    let total: Int64
    let free: Int64

    static func load() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let total = Int64(v.volumeTotalCapacity ?? 0)
            guard total > 0 else { return nil }
            let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return VolumeInfo(id: url.path, name: v.volumeName ?? url.lastPathComponent, total: total, free: free)
        }
    }
}

final class HoverModel: ObservableObject {
    @Published var text: String = ""
}

final class AppState: ObservableObject {
    enum Phase { case idle, scanning, done }

    @Published var phase: Phase = .idle
    @Published private(set) var result: ScanResult?
    @Published var selected: Node?
    @Published var zoomRoot: Node?
    @Published var highlightExt: Int32?
    @Published private(set) var treeVersion = 0
    @Published private(set) var extStats: [ExtStat] = []
    @Published var progressFiles: Int64 = 0
    @Published var progressBytes: Int64 = 0
    @Published var progressPath = ""
    @Published var scanPath = ""
    @Published var pendingTrash: Node?
    @Published var errorMessage: String?

    let hover = HoverModel()
    private(set) var extColors: [RGB] = []
    private var scanner: Scanner?

    static let palette: [RGB] = [
        RGB(66, 133, 244), RGB(234, 67, 53), RGB(52, 168, 83), RGB(251, 188, 5),
        RGB(0, 188, 212), RGB(171, 71, 188), RGB(255, 112, 67), RGB(124, 179, 66),
        RGB(236, 64, 122), RGB(92, 107, 192), RGB(38, 166, 154), RGB(255, 202, 40),
        RGB(141, 110, 99), RGB(186, 104, 200), RGB(77, 208, 225), RGB(174, 213, 129),
    ]

    var displayRoot: Node? { zoomRoot ?? result?.root }

    // MARK: Scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or disk to analyze"
        if panel.runModal() == .OK, let url = panel.url {
            startScan(path: url.path)
        }
    }

    func startScan(path: String) {
        scanner?.cancel()
        let scanner = Scanner()
        self.scanner = scanner
        releaseResult()
        scanPath = path
        progressFiles = 0
        progressBytes = 0
        progressPath = path
        phase = .scanning

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = scanner.scan(path: path) { files, bytes, current in
                DispatchQueue.main.async {
                    guard let self, self.scanner === scanner else { return }
                    self.progressFiles = files
                    self.progressBytes = bytes
                    self.progressPath = current
                }
            }
            DispatchQueue.main.async {
                guard let self, self.scanner === scanner else { return }
                self.scanner = nil
                if let res {
                    self.apply(res)
                } else {
                    self.phase = .idle
                    if !scanner.isCancelled {
                        self.errorMessage = "Could not read \(path)."
                    }
                }
            }
        }
    }

    func cancelScan() {
        scanner?.cancel()
        scanner = nil
        phase = .idle
    }

    func rescan() {
        guard let path = result?.rootPath ?? (scanPath.isEmpty ? nil : scanPath) else { return }
        startScan(path: path)
    }

    func closeScan() {
        releaseResult()
        phase = .idle
    }

    private func releaseResult() {
        let old = result
        result = nil
        selected = nil
        zoomRoot = nil
        highlightExt = nil
        extStats = []
        extColors = []
        hover.text = ""
        // Free a big tree off the main thread.
        if let old { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { _ = old } }
    }

    private func apply(_ res: ScanResult) {
        // Colour the biggest extensions, everything else is grey.
        var colors = [RGB](repeating: TreemapRenderer.otherColor, count: res.extNames.count)
        let order = res.extNames.indices.sorted { res.extBytes[$0] > res.extBytes[$1] }
        var p = 0
        for i in order where p < AppState.palette.count {
            if res.extNames[i].isEmpty { continue } // files without extension stay grey
            colors[i] = AppState.palette[p]
            p += 1
        }
        extColors = colors
        result = res
        rebuildExtStats()
        selected = res.root
        zoomRoot = nil
        highlightExt = nil
        treeVersion += 1
        phase = .done
    }

    private func rebuildExtStats() {
        guard let res = result else { extStats = []; return }
        var list: [ExtStat] = []
        for i in res.extNames.indices where res.extCounts[i] > 0 {
            let name = res.extNames[i]
            let desc: String
            if name.isEmpty {
                desc = "Files without extension"
            } else {
                desc = UTType(filenameExtension: name)?.localizedDescription ?? ""
            }
            let c = extColors[i]
            list.append(ExtStat(id: Int32(i), name: name.isEmpty ? "(none)" : "." + name, description: desc,
                                bytes: res.extBytes[i], count: res.extCounts[i],
                                color: Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255)))
        }
        list.sort { $0.bytes > $1.bytes }
        extStats = list
    }

    // MARK: Selection & zoom

    func hovered(_ node: Node?) {
        guard let node else { hover.text = ""; return }
        hover.text = "\(node.path)  —  \(Fmt.size(node.size))"
    }

    func zoomIn() {
        guard let sel = selected else { return }
        let target = sel.isDirectory ? sel : sel.parent
        guard let target, target !== displayRoot else { return }
        zoomRoot = (target === result?.root) ? nil : target
    }

    /// Double-click in the treemap: zoom one level deeper towards the clicked item.
    func zoomToward(_ leaf: Node) {
        guard let base = displayRoot else { return }
        var n: Node? = leaf
        while let c = n, c.parent !== base { n = c.parent }
        if let c = n, c.isDirectory, !c.children.isEmpty {
            zoomRoot = c
            selected = c
        }
    }

    func zoomOut() {
        guard let z = zoomRoot, let p = z.parent else { return }
        zoomRoot = (p === result?.root) ? nil : p
    }

    func zoomReset() { zoomRoot = nil }

    var canZoomOut: Bool { zoomRoot != nil }

    // MARK: Actions

    func reveal(_ node: Node?) {
        guard let node else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func open(_ node: Node?) {
        guard let node else { return }
        NSWorkspace.shared.open(node.url)
    }

    func copyPath(_ node: Node?) {
        guard let node else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    func requestTrash(_ node: Node?) {
        guard let node, node.parent != nil else { return }
        pendingTrash = node
    }

    func trash(_ node: Node) {
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            remove(node)
        } catch {
            errorMessage = "Could not move “\(node.name)” to the Trash:\n\(error.localizedDescription)"
        }
    }

    private func remove(_ node: Node) {
        guard let parent = node.parent, let res = result else { return }
        treeLock.lock()
        if let i = parent.children.firstIndex(where: { $0 === node }) {
            parent.children.remove(at: i)
        }
        var a: Node? = parent
        while let n = a {
            n.size -= node.size
            n.files -= node.files
            n.subdirs -= node.subdirs + (node.isDirectory ? 1 : 0)
            a = n.parent
            if let up = a { up.children.sort { $0.size > $1.size } }
        }
        // update extension statistics
        var stack = [node]
        while let n = stack.popLast() {
            if n.isDirectory {
                stack.append(contentsOf: n.children)
            } else if n.ext >= 0 && Int(n.ext) < res.extBytes.count {
                res.extBytes[Int(n.ext)] -= n.size
                res.extCounts[Int(n.ext)] -= 1
            }
        }
        node.parent = nil
        treeLock.unlock()

        if let z = zoomRoot, node.contains(z) { zoomRoot = (parent === res.root) ? nil : parent }
        selected = parent
        rebuildExtStats()
        if let h = highlightExt, !extStats.contains(where: { $0.id == h }) { highlightExt = nil }
        treeVersion += 1
    }

    // MARK: Context menu

    func makeMenu(for node: Node) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Open") { [weak self] in self?.open(node) })
        menu.addItem(ClosureMenuItem("Reveal in Finder") { [weak self] in self?.reveal(node) })
        menu.addItem(ClosureMenuItem("Copy Path") { [weak self] in self?.copyPath(node) })
        menu.addItem(.separator())
        if node.isDirectory {
            menu.addItem(ClosureMenuItem("Zoom Treemap Into Folder") { [weak self] in
                self?.selected = node
                self?.zoomIn()
            })
        }
        let z = ClosureMenuItem("Zoom Out") { [weak self] in self?.zoomOut() }
        z.isEnabled = canZoomOut
        menu.addItem(z)
        menu.addItem(.separator())
        let t = ClosureMenuItem("Move to Trash…") { [weak self] in self?.requestTrash(node) }
        t.isEnabled = node.parent != nil
        menu.addItem(t)
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
}
