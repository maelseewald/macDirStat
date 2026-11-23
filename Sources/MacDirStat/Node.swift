import Foundation

enum NodeKind: UInt8 {
    case file, directory, symlink, other
}

/// One file or folder in the scanned tree.
/// `size` is the allocated size on disk (what actually uses space), summed over the subtree.
final class Node {
    let name: String
    weak var parent: Node?
    var children: [Node] = []          // always kept sorted by size, largest first
    var size: Int64 = 0
    var files: Int64 = 0               // number of files in subtree
    var subdirs: Int64 = 0             // number of folders in subtree (excluding self)
    var mtime: Int64 = 0               // seconds since 1970 (newest in subtree for folders)
    var ext: Int32 = -1                // index into ScanResult.extNames (files only)
    let kind: NodeKind
    var unreadable = false

    init(name: String, kind: NodeKind, parent: Node?) {
        self.name = name
        self.kind = kind
        self.parent = parent
    }

    var isDirectory: Bool { kind == .directory }

    var path: String {
        var parts: [String] = []
        var n: Node? = self
        while let cur = n {
            parts.append(cur.name)
            n = cur.parent
        }
        parts.reverse()
        var p = parts[0]
        for comp in parts.dropFirst() {
            if !p.hasSuffix("/") { p += "/" }
            p += comp
        }
        return p
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// True if `other` is self or lies inside self.
    func contains(_ other: Node) -> Bool {
        var n: Node? = other
        while let c = n {
            if c === self { return true }
            n = c.parent
        }
        return false
    }

    /// Extension of the biggest file found by following the largest child.
    var dominantExt: Int32 {
        var n = self
        while n.isDirectory, let c = n.children.first, c.size > 0 { n = c }
        return n.isDirectory ? -1 : n.ext
    }

    var modificationDate: Date? {
        mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil
    }
}

final class ScanResult {
    let root: Node
    let rootPath: String
    var extNames: [String]
    var extBytes: [Int64]
    var extCounts: [Int64]
    let errors: Int
    let duration: TimeInterval
    let finishedAt = Date()

    init(root: Node, rootPath: String, extNames: [String], extBytes: [Int64], extCounts: [Int64], errors: Int, duration: TimeInterval) {
        self.root = root
        self.rootPath = rootPath
        self.extNames = extNames
        self.extBytes = extBytes
        self.extCounts = extCounts
        self.errors = errors
        self.duration = duration
    }
}
