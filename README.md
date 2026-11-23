# MacDirStat

A WinDirStat-style disk usage analyzer for macOS (native SwiftUI + AppKit).

- **Folder tree** (top left): every folder sorted by size, with a "Subtree %" bar, file count and last change. Click a column header to sort.
- **File types** (top right): space per file extension, with the colour used in the treemap. Click a type to highlight it in the treemap; **Esc** clears.
- **Treemap** (bottom): each rectangle is a file, sized by disk usage, coloured by type. Click one to select it in the tree, double-click to zoom into that folder, right-click for actions. Hover to see the path in the status bar.

## Build & start

```bash
git clone https://github.com/maelseewald/macDirStat.git
cd macDirStat
./build.sh                 # creates MacDirStat.app (takes ~30 s the first time)
open MacDirStat.app        # or drag MacDirStat.app into /Applications
```

Scan a folder straight from Terminal: `open MacDirStat.app --args --scan ~/Downloads`

## Full Disk Access (recommended)

Without it, macOS asks for each protected folder (Desktop, Documents, Downloads…) and some folders (Mail, Safari, other users' data) are skipped and counted as "unreadable".

System Settings → Privacy & Security → Full Disk Access → **+** → choose `MacDirStat.app` → switch it on → restart MacDirStat.

After every `./build.sh` the app's signature changes, so you may have to switch Full Disk Access off and on again.

## Shortcuts

| Keys | Action |
|---|---|
| ⌘O | Open folder… |
| ⇧⌘H / ⇧⌘D | Scan home folder / whole disk |
| ⌘R | Rescan |
| ⌘+ / ⌘- / ⌘0 | Treemap zoom in / out / to top |
| ⇧⌘R | Reveal in Finder |
| ⌘↓ | Open |
| ⌥⌘C | Copy path |
| ⌘⌫ | Move to Trash (asks first; can be undone from the Trash) |
| Esc | Clear file-type highlight |

## Notes

- Sizes are the real space used on disk (allocated blocks), like `du`. Hard-linked files are counted once. iCloud files that are not downloaded count as 0.
- "Scan Whole Disk" stays on your startup disk and does not count external drives or disk images. The total is a bit lower than "used" in Finder because APFS snapshots, swap and system-reserved space are not regular files.
- Nothing is ever deleted without the confirmation dialog, and deleting means *Move to Trash*.
