import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The folder tree (top-left pane), backed by NSOutlineView so it stays fast with millions of items.
struct DirectoryOutline: NSViewRepresentable {
    @ObservedObject var state: AppState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let outline = NSOutlineView()
        outline.headerView = NSTableHeaderView()
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .fullWidth
        outline.rowHeight = 20
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.indentationPerLevel = 14
        outline.autosaveExpandedItems = false

        func col(_ id: String, _ title: String, _ width: CGFloat, _ sortKey: String?, ascending: Bool) -> NSTableColumn {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 50
            if let sortKey { column.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: ascending) }
            return column
        }
        let nameCol = col("name", "Name", 270, "name", ascending: true)
        nameCol.minWidth = 150
        outline.addTableColumn(nameCol)
        outline.addTableColumn(col("bar", "Subtree %", 110, "size", ascending: false))
        let sizeCol = col("size", "Size", 90, "size", ascending: false)
        sizeCol.headerCell.alignment = .right
        outline.addTableColumn(sizeCol)
        let filesCol = col("files", "Files", 80, "files", ascending: false)
        filesCol.headerCell.alignment = .right
        outline.addTableColumn(filesCol)
        outline.addTableColumn(col("modified", "Last Change", 130, "modified", ascending: false))
        outline.outlineTableColumn = nameCol

        outline.dataSource = c
        outline.delegate = c
        outline.target = c
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = c
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        c.outline = outline
        c.suppress = true
        outline.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        c.suppress = false
        c.sync()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.sync()
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let state: AppState
        weak var outline: NSOutlineView?
        var root: Node?
        var lastVersion = -1
        weak var lastSelected: Node?
        var suppress = false
        var sortKey = "size"
        var ascending = false
        var cache: [ObjectIdentifier: [Node]] = [:]
        var iconCache: [Int32: NSImage] = [:]
        lazy var folderIcon: NSImage = icon(for: .folder)

        init(state: AppState) { self.state = state }

        func sync() {
            guard let outline else { return }
            suppress = true
            defer { suppress = false }
            let newRoot = state.result?.root
            if newRoot !== root {
                root = newRoot
                cache.removeAll()
                iconCache.removeAll()
                lastVersion = state.treeVersion
                lastSelected = nil
                outline.reloadData()
                if let r = root { outline.expandItem(r) }
            } else if state.treeVersion != lastVersion {
                lastVersion = state.treeVersion
                cache.removeAll()
                outline.reloadData()
                lastSelected = nil
            }
            if state.selected !== lastSelected {
                reveal(state.selected)
            }
        }

        private func reveal(_ node: Node?) {
            guard let outline else { return }
            lastSelected = node
            guard let node, let root, root.contains(node) else {
                outline.deselectAll(nil)
                return
            }
            var chain: [Node] = []
            var p = node.parent
            while let c = p { chain.append(c); p = c.parent }
            for a in chain.reversed() { outline.expandItem(a) }
            let row = outline.row(forItem: node)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
        }

        // MARK: Sorting

        func children(of node: Node) -> [Node] {
            if sortKey == "size" && !ascending { return node.children }
            let id = ObjectIdentifier(node)
            if let c = cache[id] { return c }
            let asc = ascending
            let sorted: [Node]
            switch sortKey {
            case "name":
                sorted = node.children.sorted {
                    let r = $0.name.localizedStandardCompare($1.name)
                    return asc ? r == .orderedAscending : r == .orderedDescending
                }
            case "files":
                sorted = node.children.sorted { asc ? $0.files < $1.files : $0.files > $1.files }
            case "modified":
                sorted = node.children.sorted { asc ? $0.mtime < $1.mtime : $0.mtime > $1.mtime }
            default:
                sorted = node.children.sorted { asc ? $0.size < $1.size : $0.size > $1.size }
            }
            cache[id] = sorted
            return sorted
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let d = outlineView.sortDescriptors.first, let key = d.key else { return }
            sortKey = key
            ascending = d.ascending
            cache.removeAll()
            let sel = lastSelected
            let wasSuppressed = suppress
            suppress = true
            outlineView.reloadData()
            reveal(sel)
            suppress = wasSuppressed
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node else { return root == nil ? 0 : 1 }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? Node else { return root! }
            return children(of: node)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            return node.isDirectory && !node.children.isEmpty
        }

        // MARK: Delegate

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !suppress, let outline else { return }
            let node = outline.item(atRow: outline.selectedRow) as? Node
            lastSelected = node
            if let node { state.selected = node }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let outline, let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
            if node.isDirectory {
                if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            } else {
                state.open(node)
            }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
            if outline.selectedRow != outline.clickedRow {
                outline.selectRowIndexes(IndexSet(integer: outline.clickedRow), byExtendingSelection: false)
            }
            for item in state.makeMenu(for: node).items {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
        }

        private func icon(for type: UTType) -> NSImage {
            let img = NSWorkspace.shared.icon(for: type)
            img.size = NSSize(width: 16, height: 16)
            return img
        }

        private func icon(for node: Node) -> NSImage {
            if node.isDirectory { return folderIcon }
            if let i = iconCache[node.ext] { return i }
            var type: UTType = .data
            if node.kind == .symlink {
                type = .symbolicLink
            } else if let res = state.result, node.ext >= 0, Int(node.ext) < res.extNames.count,
                      !res.extNames[Int(node.ext)].isEmpty,
                      let t = UTType(filenameExtension: res.extNames[Int(node.ext)]) {
                type = t
            }
            let img = icon(for: type)
            iconCache[node.ext] = img
            return img
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let column = tableColumn else { return nil }
            let id = column.identifier
            switch id.rawValue {
            case "name":
                let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NameCell) ?? NameCell(id: id)
                cell.imageView?.image = icon(for: node)
                var title = node.name
                if node.unreadable { title += "  (no access)" }
                cell.textField?.stringValue = title
                cell.textField?.textColor = node.unreadable ? .secondaryLabelColor : .labelColor
                return cell
            case "bar":
                let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? PercentBarView) ?? PercentBarView(id: id)
                if let p = node.parent, p.size > 0 {
                    cell.fraction = Double(node.size) / Double(p.size)
                } else {
                    cell.fraction = node.parent == nil ? 1 : 0
                }
                return cell
            default:
                let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? TextCell) ?? TextCell(id: id, rightAligned: id.rawValue != "modified")
                switch id.rawValue {
                case "size": cell.textField?.stringValue = Fmt.size(node.size)
                case "files": cell.textField?.stringValue = node.isDirectory ? Fmt.count(node.files) : ""
                default: cell.textField?.stringValue = Fmt.date(node.modificationDate)
                }
                return cell
            }
        }
    }
}

final class NameCell: NSTableCellView {
    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyDown
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        tf.font = .systemFont(ofSize: 12)
        addSubview(iv)
        addSubview(tf)
        imageView = iv
        textField = tf
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
}

final class TextCell: NSTableCellView {
    init(id: NSUserInterfaceItemIdentifier, rightAligned: Bool) {
        super.init(frame: .zero)
        identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.alignment = rightAligned ? .right : .left
        tf.lineBreakMode = .byTruncatingTail
        tf.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        addSubview(tf)
        textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            tf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
}

final class PercentBarView: NSTableCellView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 3, dy: 4)
        guard track.width > 4 else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let f = max(0, min(1, fraction))
        if f > 0 {
            var fill = track
            fill.size.width = max(2, track.width * f)
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }
        let text = String(format: "%.1f %%", f * 100) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: track.maxX - size.width - 4, y: track.midY - size.height / 2), withAttributes: attrs)
    }
}
