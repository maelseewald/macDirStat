import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            switch state.phase {
            case .idle:
                WelcomeView()
            case .scanning:
                ScanningView()
            case .done:
                MainSplitView()
            }
            Divider()
            StatusBar(hover: state.hover)
        }
        .toolbar { toolbarContent }
        .navigationTitle(title)
        .onAppear {
            // Optional: `open MacDirStat.app --args --scan /some/folder` starts scanning right away.
            let args = CommandLine.arguments
            if state.phase == .idle, let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
                state.startScan(path: (args[i + 1] as NSString).expandingTildeInPath)
            }
        }
        .alert("Move to Trash?",
               isPresented: Binding(get: { state.pendingTrash != nil }, set: { if !$0 { state.pendingTrash = nil } }),
               presenting: state.pendingTrash) { node in
            Button("Move to Trash", role: .destructive) { state.trash(node) }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text("“\(node.name)” (\(Fmt.size(node.size))) will be moved to the Trash.\n\n\(node.path)")
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    private var title: String {
        guard let r = state.result else { return "MacDirStat" }
        return "MacDirStat — \(r.rootPath)"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { state.chooseFolder() } label: { Label("Open Folder", systemImage: "folder.badge.plus") }
                .help("Choose a folder or disk to scan (⌘O)")
                .disabled(state.phase == .scanning)
            Button { state.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .help("Scan again (⌘R)")
                .disabled(state.result == nil)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { state.zoomIn() } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .help("Show only the selected folder in the treemap (⌘+)")
                .disabled(state.selected == nil)
            Button { state.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .help("Zoom the treemap out one level (⌘-)")
                .disabled(!state.canZoomOut)
            Button { state.reveal(state.selected) } label: { Label("Reveal in Finder", systemImage: "finder") }
                .help("Show the selected item in Finder (⇧⌘R)")
                .disabled(state.selected == nil)
            Button { state.requestTrash(state.selected) } label: { Label("Move to Trash", systemImage: "trash") }
                .help("Move the selected item to the Trash (⌘⌫)")
                .disabled(state.selected?.parent == nil)
        }
    }
}

struct MainSplitView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VSplitView {
            HSplitView {
                DirectoryOutline(state: state)
                    .frame(minWidth: 420, maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                ExtensionTable()
                    .frame(minWidth: 260, idealWidth: 360, maxWidth: 700, minHeight: 140, maxHeight: .infinity)
            }
            .frame(minHeight: 140, idealHeight: 320, maxHeight: .infinity)
            TreemapPane(state: state)
                .frame(minHeight: 140, idealHeight: 380, maxHeight: .infinity)
        }
    }
}

struct ExtensionTable: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let total = max(1, state.result?.root.size ?? 1)
        Table(state.extStats, selection: $state.highlightExt) {
            TableColumn("Extension") { e in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(e.color).frame(width: 12, height: 12)
                    Text(e.name)
                }
            }
            .width(min: 70, ideal: 90)
            TableColumn("Description") { e in
                Text(e.description).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 120)
            TableColumn("Size") { e in
                Text(Fmt.size(e.bytes)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 75)
            TableColumn("%") { e in
                Text(String(format: "%.1f", Double(e.bytes) / Double(total) * 100))
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 36, ideal: 44)
            TableColumn("Files") { e in
                Text(Fmt.count(e.count)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 44, ideal: 60)
        }
        .help("Select a file type to highlight it in the treemap. Press Esc to clear.")
    }
}

struct TreemapPane: NSViewRepresentable {
    @ObservedObject var state: AppState

    func makeNSView(context: Context) -> TreemapView {
        let v = TreemapView()
        let state = self.state
        v.onSelect = { [weak state] n in state?.selected = n }
        v.onHover = { [weak state] n in state?.hovered(n) }
        v.onDoubleClick = { [weak state] n in state?.zoomToward(n) }
        v.menuProvider = { [weak state] n in state?.makeMenu(for: n) }
        return v
    }

    func updateNSView(_ v: TreemapView, context: Context) {
        v.update(root: state.displayRoot, colors: state.extColors, highlight: state.highlightExt ?? -1,
                 version: state.treeVersion, selected: state.selected)
    }
}

struct StatusBar: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var hover: HoverModel

    var body: some View {
        HStack(spacing: 12) {
            Text(leftText)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(hover.text.isEmpty ? .secondary : .primary)
            Spacer(minLength: 8)
            if let r = state.result {
                if r.errors > 0 {
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("\(Fmt.count(Int64(r.errors))) items unreadable", systemImage: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(.link)
                    .help("Some folders could not be read. Click to open Full Disk Access settings.")
                }
                Text("\(Fmt.size(r.root.size)) in \(Fmt.count(r.root.files)) files · scanned in \(String(format: "%.1f", r.duration)) s")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 24)
    }

    private var leftText: String {
        if !hover.text.isEmpty { return hover.text }
        if let s = state.selected { return "\(s.path)  —  \(Fmt.size(s.size))" }
        return "Ready"
    }
}

struct WelcomeView: View {
    @EnvironmentObject var state: AppState
    @State private var volumes: [VolumeInfo] = []

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("MacDirStat").font(.largeTitle.bold())
                Text("See what is using your disk space.").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { state.startScan(path: NSHomeDirectory()) } label: {
                    Label("Scan Home Folder", systemImage: "house").frame(minWidth: 150)
                }
                Button { state.startScan(path: "/") } label: {
                    Label("Scan Whole Disk", systemImage: "internaldrive").frame(minWidth: 150)
                }
                Button { state.chooseFolder() } label: {
                    Label("Choose Folder…", systemImage: "folder").frame(minWidth: 150)
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)

            if !volumes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Volumes").font(.headline)
                    ForEach(volumes) { v in
                        HStack(spacing: 12) {
                            Image(systemName: v.id == "/" ? "internaldrive.fill" : "externaldrive.fill")
                                .font(.title2).foregroundStyle(.secondary).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(v.name).fontWeight(.medium)
                                    Spacer()
                                    Text("\(Fmt.size(v.total - v.free)) used of \(Fmt.size(v.total)) · \(Fmt.size(v.free)) free")
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                ProgressView(value: Double(max(0, v.total - v.free)), total: Double(max(1, v.total)))
                            }
                            Button("Scan") { state.startScan(path: v.id) }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 620)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }

            Text("Tip: to scan everything (including Mail, Photos libraries and other protected folders), give MacDirStat **Full Disk Access** in System Settings → Privacy & Security.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Spacer(minLength: 10)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { volumes = VolumeInfo.load() }
    }
}

struct ScanningView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Scanning \(state.scanPath)").font(.title3.weight(.semibold))
            HStack(spacing: 24) {
                VStack {
                    Text(Fmt.count(state.progressFiles)).font(.title2.monospacedDigit().weight(.medium))
                    Text("files").font(.caption).foregroundStyle(.secondary)
                }
                VStack {
                    Text(Fmt.size(state.progressBytes)).font(.title2.monospacedDigit().weight(.medium))
                    Text("found").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(state.progressPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 600)
            Text("If macOS asks whether MacDirStat may access a folder, click “Allow”.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Cancel") { state.cancelScan() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
