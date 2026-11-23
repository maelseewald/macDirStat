import Foundation
import Darwin

/// Multi-threaded directory scanner (readdir + fstatat on a pool of worker threads).
/// Each folder is processed by exactly one worker, which is the only thread that touches that folder's node,
/// so the tree is built without locking individual nodes.
final class Scanner {
    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
        queue.cancelAll()
    }

    // MARK: Work queue

    private struct Task {
        let node: Node
        let path: String
    }

    private final class WorkQueue {
        private let cond = NSCondition()
        private var items: [Task] = []
        private var active = 0
        private var finished = false

        func push(_ tasks: [Task]) {
            guard !tasks.isEmpty else { return }
            cond.lock()
            if !finished {
                items.append(contentsOf: tasks)
                cond.broadcast()
            }
            cond.unlock()
        }

        /// Next task, or nil when all work is done (or cancelled).
        func pop() -> Task? {
            cond.lock()
            defer { cond.unlock() }
            while true {
                if finished { return nil }
                if let t = items.popLast() {
                    active += 1
                    return t
                }
                if active == 0 {
                    finished = true
                    cond.broadcast()
                    return nil
                }
                cond.wait()
            }
        }

        func taskDone() {
            cond.lock()
            active -= 1
            if active == 0 && items.isEmpty {
                finished = true
            }
            cond.broadcast()
            cond.unlock()
        }

        func cancelAll() {
            cond.lock()
            items.removeAll()
            finished = true
            cond.broadcast()
            cond.unlock()
        }
    }

    private let queue = WorkQueue()

    // MARK: Shared state (guarded by `stateLock`)

    private let stateLock = NSLock()
    private var seenInodes = Set<InodeKey>()
    private var extIndex: [String: Int32] = [:]
    private var extNames: [String] = []
    private var errors = 0
    private var fileCount: Int64 = 0
    private var byteCount: Int64 = 0
    private var lastPath = ""

    private struct InodeKey: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    private var allowedDevices = Set<Int32>()
    private var excludedPaths = Set<String>()

    private static let nameOffset: Int = MemoryLayout<dirent>.offset(of: \dirent.d_name)!

    private static func fileExtension(_ name: String) -> String {
        let u = name.utf8
        guard let dot = u.lastIndex(of: UInt8(ascii: ".")), dot != u.startIndex else { return "" }
        let after = u.index(after: dot)
        let len = u.distance(from: after, to: u.endIndex)
        guard len > 0, len <= 12 else { return "" }
        let ext = String(decoding: u[after...], as: UTF8.self)
        if ext.contains(" ") { return "" }
        return ext.lowercased()
    }

    private func globalExtIndex(_ ext: String) -> Int32 {
        stateLock.lock(); defer { stateLock.unlock() }
        if let i = extIndex[ext] { return i }
        let i = Int32(extNames.count)
        extIndex[ext] = i
        extNames.append(ext)
        return i
    }

    // MARK: Scan

    /// Scans `rootPath`. Returns nil if cancelled or the path can't be read.
    /// `progress` is called from a background thread about 10 times per second.
    func scan(path rootPath: String, progress: @escaping (Int64, Int64, String) -> Void) -> ScanResult? {
        let start = Date()
        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else { return nil }

        // Stay on the volume(s) we started on, so other disks / disk images are not counted.
        allowedDevices = [rootStat.st_dev]
        if rootPath == "/" {
            var st = stat()
            if lstat("/System/Volumes/Data", &st) == 0 { allowedDevices.insert(st.st_dev) }
            // The data volume is already reachable via firmlinks (/Users, /Applications, …):
            // skip the duplicate mount paths and pseudo file systems.
            excludedPaths = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/Network", "/cores"]
        }

        let root = Node(name: rootPath, kind: .directory, parent: nil)
        root.mtime = Int64(rootStat.st_mtimespec.tv_sec)
        // Make sure the root folder itself is readable.
        guard let probe = opendir(rootPath) else { return nil }
        closedir(probe)

        queue.push([Task(node: root, path: rootPath)])

        let workers = max(4, min(16, ProcessInfo.processInfo.activeProcessorCount))
        let group = DispatchGroup()
        for _ in 0..<workers {
            group.enter()
            let t = Thread { [self] in
                self.workerLoop()
                group.leave()
            }
            t.stackSize = 1 << 20
            t.qualityOfService = .userInitiated
            t.start()
        }

        // Report progress while the workers run.
        while group.wait(timeout: .now() + 0.1) == .timedOut {
            if isCancelled { break }
            stateLock.lock()
            let f = fileCount, b = byteCount, p = lastPath
            stateLock.unlock()
            progress(f, b, p)
        }
        group.wait()
        if isCancelled { return nil }

        stateLock.lock()
        progress(fileCount, byteCount, "Finishing…")
        let names = extNames
        let errs = errors
        stateLock.unlock()

        var extBytes = [Int64](repeating: 0, count: names.count)
        var extCounts = [Int64](repeating: 0, count: names.count)
        Scanner.finalize(root, &extBytes, &extCounts)

        return ScanResult(root: root, rootPath: rootPath, extNames: names, extBytes: extBytes,
                          extCounts: extCounts, errors: errs, duration: Date().timeIntervalSince(start))
    }

    private func workerLoop() {
        var extCache: [String: Int32] = [:]
        var pendingFiles: Int64 = 0
        var pendingBytes: Int64 = 0
        var pendingErrors = 0
        var processed = 0

        func flush(_ path: String?) {
            stateLock.lock()
            fileCount += pendingFiles
            byteCount += pendingBytes
            errors += pendingErrors
            if let path { lastPath = path }
            stateLock.unlock()
            pendingFiles = 0; pendingBytes = 0; pendingErrors = 0
        }

        while let task = queue.pop() {
            autoreleasepool {
                process(task, &extCache, &pendingFiles, &pendingBytes, &pendingErrors)
            }
            processed += 1
            if processed & 31 == 0 || pendingFiles > 5000 { flush(task.path) }
            queue.taskDone()
        }
        flush(nil)
    }

    private func process(_ task: Task, _ extCache: inout [String: Int32],
                         _ files: inout Int64, _ bytes: inout Int64, _ errs: inout Int) {
        let node = task.node
        guard let dir = opendir(task.path) else {
            node.unreadable = true
            errs += 1
            return
        }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        let prefix = task.path.hasSuffix("/") ? task.path : task.path + "/"
        var subtasks: [Task] = []
        var st = stat()

        while let ent = readdir(dir) {
            let namePtr = UnsafeRawPointer(ent).advanced(by: Scanner.nameOffset).assumingMemoryBound(to: CChar.self)
            let nameLen = Int(ent.pointee.d_namlen)
            if nameLen == 1 && namePtr[0] == 46 { continue }                       // "."
            if nameLen == 2 && namePtr[0] == 46 && namePtr[1] == 46 { continue }  // ".."
            if fstatat(fd, namePtr, &st, AT_SYMLINK_NOFOLLOW) != 0 {
                errs += 1
                continue
            }
            let name = String(decoding: UnsafeRawBufferPointer(start: namePtr, count: nameLen), as: UTF8.self)
            let fmt = st.st_mode & S_IFMT

            if fmt == S_IFDIR {
                if !allowedDevices.contains(st.st_dev) { continue }   // another volume mounted here
                let childPath = prefix + name
                if !excludedPaths.isEmpty && excludedPaths.contains(childPath) { continue }
                let child = Node(name: name, kind: .directory, parent: node)
                child.mtime = Int64(st.st_mtimespec.tv_sec)
                node.children.append(child)
                subtasks.append(Task(node: child, path: childPath))
                continue
            }

            var alloc = Int64(st.st_blocks) * 512
            if st.st_nlink > 1 {
                let key = InodeKey(dev: st.st_dev, ino: st.st_ino)
                stateLock.lock()
                let isNew = seenInodes.insert(key).inserted
                stateLock.unlock()
                if !isNew { alloc = 0 }   // hard link already counted elsewhere
            }
            let kind: NodeKind = fmt == S_IFREG ? .file : (fmt == S_IFLNK ? .symlink : .other)
            let child = Node(name: name, kind: kind, parent: node)
            child.size = alloc
            child.files = 1
            child.mtime = Int64(st.st_mtimespec.tv_sec)
            let ext = Scanner.fileExtension(name)
            if let i = extCache[ext] {
                child.ext = i
            } else {
                let i = globalExtIndex(ext)
                extCache[ext] = i
                child.ext = i
            }
            node.children.append(child)
            files += 1
            bytes += alloc
        }
        queue.push(subtasks)
    }

    /// Sums sizes bottom-up, sorts every folder's children by size (largest first),
    /// and collects per-extension totals.
    private static func finalize(_ node: Node, _ extBytes: inout [Int64], _ extCounts: inout [Int64]) {
        var size: Int64 = 0, files: Int64 = 0, dirs: Int64 = 0, mtime = node.mtime
        for c in node.children {
            if c.isDirectory {
                finalize(c, &extBytes, &extCounts)
                dirs += 1 + c.subdirs
            } else if c.ext >= 0 {
                extBytes[Int(c.ext)] += c.size
                extCounts[Int(c.ext)] += 1
            }
            size += c.size
            files += c.files
            if c.mtime > mtime { mtime = c.mtime }
        }
        node.size = size
        node.files = files
        node.subdirs = dirs
        node.mtime = mtime
        node.children.sort { $0.size > $1.size }
    }
}
