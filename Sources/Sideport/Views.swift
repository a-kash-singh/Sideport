import SwiftUI
import QuickLook
import UniformTypeIdentifiers

private let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            if model.device == nil {
                ConnectView()
            } else if model.storages.isEmpty {
                ContentUnavailableView {
                    Label("Waiting for access", systemImage: "lock.iphone")
                } description: {
                    Text("Unlock your phone. If asked, allow access to phone data and choose \"File transfer\" in the USB notification.")
                }
            } else {
                Browser()
            }
        }
        .alert("Import finished", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.notice ?? "")
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { model.storage }, set: { model.select(storage: $0) })) {
            if let d = model.device {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "smartphone")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.tint)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(.headline).lineLimit(1)
                            HStack(spacing: 4) {
                                Text([d.manufacturer, d.model].filter { !$0.isEmpty && $0 != d.name }.joined(separator: " "))
                                    .lineLimit(1)
                                if let b = model.battery {
                                    Image(systemName: batteryIcon(b))
                                    Text("\(b)%")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .selectionDisabled()
                }
                Section("Storage") {
                    ForEach(model.storages) { s in
                        StorageRow(storage: s).tag(Optional(s.id))
                    }
                }
                Section("Shortcuts") {
                    Button { model.importNewPhotos() } label: {
                        Label("Import New Photos", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                    .disabled(model.importing)
                    ForEach(Shortcut.all) { s in
                        Button { Task { await model.jump(to: s.paths) } } label: {
                            Label(s.title, systemImage: s.icon)
                        }
                        .buttonStyle(.plain)
                        .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Circle().fill(model.device == nil ? Color.orange : Color.green).frame(width: 7, height: 7)
                Text(model.device == nil ? "No device" : "Connected via USB")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

struct StorageRow: View {
    let storage: Storage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(storage.name, systemImage: storage.name.localizedCaseInsensitiveContains("sd") ? "sdcard" : "internaldrive")
            ProgressView(value: Double(storage.capacity - min(storage.free, storage.capacity)), total: Double(max(storage.capacity, 1)))
                .controlSize(.small)
            Text("\(bytes(storage.free)) free of \(bytes(storage.capacity))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Connect

struct ConnectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(.tint.opacity(0.12)).frame(width: 120, height: 120)
                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: model.status == .searching)
            }
            VStack(spacing: 6) {
                Text("Connect an Android device").font(.title2.weight(.semibold))
                Text("Sideport finds your phone automatically.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Plug the phone into this Mac with a USB cable.")
                step(2, "Unlock the phone.")
                step(3, "Tap the USB notification and choose \"File transfer\".")
            }
            .padding(18)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            if case .failed(let msg) = model.status {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Try Again") { Task { await model.connect() } }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices").foregroundStyle(.secondary)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.tint))
            Text(text)
        }
    }
}

// MARK: - Browser

enum ViewMode: String { case list, grid }

struct Browser: View {
    @Environment(AppModel.self) private var model
    @AppStorage("viewMode") private var viewMode = ViewMode.list
    @State private var sortOrder = [KeyPathComparator(\Item.name, comparator: .localizedStandard)]
    @State private var dropTargeted = false
    @State private var prompt: NamePrompt?
    @State private var confirmDelete: Set<Item.ID>?

    private var rows: [Item] {
        let sorted = model.visibleItems.sorted(using: sortOrder)
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if viewMode == .grid { grid } else { table }
        }
        .onKeyPress(.space) { model.quickLook(); return .handled }
        .quickLookPreview($model.previewURL)
        .onDeleteCommand { if !model.selection.isEmpty { confirmDelete = model.selection } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let url = URL(dataRepresentation: u, relativeTo: nil) { urls.append(url) }
                }
                model.upload(urls)
            }
            return true
        }
        .overlay { dropOverlay }
        .overlay {
            if rows.isEmpty, !model.loading {
                if model.filter.isEmpty {
                    ContentUnavailableView("Empty Folder", systemImage: "folder",
                                           description: Text("Drag files here to copy them to your phone."))
                } else {
                    ContentUnavailableView.search(text: model.filter)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { PathBar() }
        .safeAreaInset(edge: .bottom, spacing: 0) { TransferBar() }
        .searchable(text: $model.filter, placement: .toolbar, prompt: "Filter")
        .navigationTitle(model.path.last?.name ?? model.currentStorage?.name ?? "Sideport")
        .toolbar { toolbar }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: Binding(get: { prompt?.name ?? "" }, set: { prompt?.name = $0 }))
            Button("Cancel", role: .cancel) {}
            Button("OK") {
                guard let p = prompt else { return }
                let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let item = p.item { model.rename(item, to: name) } else { model.createFolder(named: name) }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let ids = confirmDelete { model.delete(ids); model.selection.subtract(ids) }
            }
        } message: {
            Text("This permanently deletes them from the phone. It cannot be undone.")
        }
    }

    private var table: some View {
        @Bindable var model = model
        return Table(of: Item.self, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 8) {
                    Image(nsImage: Icons.icon(for: item)).resizable().frame(width: 18, height: 18)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 220, ideal: 360)
            TableColumn("Size", value: \.size) { item in
                Text(item.isFolder ? "--" : bytes(item.size))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Date Modified", value: \.modified) { item in
                Text(item.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Kind") { item in
                Text(Icons.kind(for: item)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 120)
        } rows: {
            ForEach(rows) { item in
                TableRow(item).itemProvider { model.itemProvider(for: item) }
            }
        }
        .contextMenu(forSelectionType: Item.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            if ids.count == 1, let item = model.items.first(where: { $0.id == ids.first }) { model.open(item) }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 14) {
                ForEach(rows) { item in
                    GridCell(item: item, selected: model.selection.contains(item.id))
                        .onTapGesture(count: 2) { model.open(item) }
                        .onTapGesture { select(item) }
                        .onDrag { model.itemProvider(for: item) }
                        .contextMenu { menu(for: model.selection.contains(item.id) ? model.selection : [item.id]) }
                }
            }
            .padding(16)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = [] }
        .contextMenu { menu(for: []) }
        .focusable()
        .focusEffectDisabled()
    }

    private func select(_ item: Item) {
        if NSEvent.modifierFlags.contains(.command) {
            if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
        } else {
            model.selection = [item.id]
        }
    }

    @ViewBuilder private func menu(for ids: Set<Item.ID>) -> some View {
        if ids.count == 1, let item = model.items.first(where: { $0.id == ids.first }) {
            Button(item.isFolder ? "Open" : "Open on Mac") { model.open(item) }
            if !item.isFolder {
                Button("Quick Look") { model.selection = [item.id]; model.quickLook() }
            }
            Button("Rename...") { prompt = NamePrompt(title: "Rename", name: item.name, item: item) }
            Divider()
        }
        if !ids.isEmpty {
            Button("Download to Downloads") { model.download(ids, to: downloads) }
            Button("Download To...") { model.pickDownload(ids) }
            Divider()
            Button("Delete", role: .destructive) { confirmDelete = ids }
        } else {
            Button("New Folder...") { prompt = NamePrompt(title: "New Folder", name: "untitled folder") }
            Button("Upload Files...") { model.pickUpload() }
            Button("Import New Photos") { model.importNewPhotos() }
        }
    }

    private var deleteTitle: String {
        let n = confirmDelete?.count ?? 0
        if n == 1, let item = model.items.first(where: { $0.id == confirmDelete?.first }) { return "Delete \"\(item.name)\"?" }
        return "Delete \(n) items?"
    }

    @ViewBuilder private var dropOverlay: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    Label("Copy to \(model.path.last?.name ?? model.currentStorage?.name ?? "phone")", systemImage: "arrow.down.doc")
                        .font(.headline)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.goUp() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(model.path.isEmpty)
                .help("Enclosing folder")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $viewMode) {
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                Label("Thumbnails", systemImage: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("Show as list or thumbnails")
            Button { model.importNewPhotos() } label: { Label("Import New Photos", systemImage: "photo.on.rectangle.angled") }
                .disabled(model.importing)
                .help("Copy photos and videos you have not imported yet to \(model.importFolder.lastPathComponent)")
            Button { prompt = NamePrompt(title: "New Folder", name: "untitled folder") } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("New folder")
            Button { model.pickUpload() } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                .help("Copy files from your Mac to the phone")
            Button { model.download(model.selection, to: downloads) } label: { Label("Download", systemImage: "square.and.arrow.down") }
                .disabled(model.selection.isEmpty)
                .help("Copy selected items to Downloads")
            Button { confirmDelete = model.selection } label: { Label("Delete", systemImage: "trash") }
                .disabled(model.selection.isEmpty)
                .help("Delete selected items")
        }
    }
}

struct GridCell: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let selected: Bool
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 108, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .bottomTrailing) {
                            if Icons.type(for: item).conforms(to: .movie) {
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white, .black.opacity(0.45))
                                    .padding(5)
                            }
                        }
                } else {
                    Image(nsImage: Icons.icon(for: item))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                }
            }
            .frame(width: 120, height: 120)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.primary.opacity(0.12) : .clear))

            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor : .clear))
        }
        .frame(width: 132)
        .help(item.name)
        .contentShape(Rectangle())
        .task(id: item.id) { thumb = await model.thumbnail(for: item) }
    }
}

struct NamePrompt {
    var title: String
    var name: String
    var item: Item?
}

struct PathBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            crumb(model.currentStorage?.name ?? "Storage", icon: "internaldrive", depth: 0)
            ForEach(Array(model.path.enumerated()), id: \.element.id) { i, item in
                Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                crumb(item.name, icon: "folder", depth: i + 1)
            }
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            Text("\(model.visibleItems.count) items").foregroundStyle(.secondary)
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func crumb(_ title: String, icon: String, depth: Int) -> some View {
        Button { model.go(toDepth: depth) } label: {
            Label(title, systemImage: icon)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(depth == model.path.count ? .primary : .secondary)
    }
}

// MARK: - Transfers

struct TransferBar: View {
    @Environment(AppModel.self) private var model
    @State private var showList = false

    var body: some View {
        if !model.transfers.isEmpty {
            HStack(spacing: 12) {
                if let t = model.activeTransfer {
                    Image(systemName: t.kind == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.name).lineLimit(1).truncationMode(.middle)
                        ProgressView(value: t.fraction).controlSize(.small)
                        TransferStats(t: t)
                    }
                    Button { model.cancelAll() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Cancel all transfers")
                } else {
                    let failed = model.transfers.filter { if case .failed = $0.state { true } else { false } }.count
                    Image(systemName: failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.title2).foregroundStyle(failed > 0 ? .orange : .green)
                    Text(failed > 0 ? "\(failed) of \(model.transfers.count) transfers failed" : "\(model.transfers.count) transfers complete")
                    Spacer()
                }
                Button("Details") { showList.toggle() }
                    .popover(isPresented: $showList, arrowEdge: .top) { TransferList() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

struct TransferStats: View {
    let t: Transfer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = max(ctx.date.timeIntervalSince(t.started), 0.5)
            let speed = Double(t.sent) / elapsed
            let left = speed > 0 ? Double(t.total - min(t.sent, t.total)) / speed : 0
            Text("\(bytes(t.sent)) of \(bytes(t.total))  -  \(bytes(UInt64(speed)))/s  -  \(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))) left")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

struct TransferList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            List(model.transfers.reversed()) { t in
                HStack(spacing: 10) {
                    Image(systemName: t.kind == .upload ? "arrow.up" : "arrow.down").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).lineLimit(1).truncationMode(.middle)
                        switch t.state {
                        case .running: ProgressView(value: t.fraction).controlSize(.mini)
                        case .done: Text(bytes(t.total)).font(.caption).foregroundStyle(.secondary)
                        case .cancelled: Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                        case .failed(let m): Text(m).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                    Spacer()
                    if let url = t.localURL, t.state == .done {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.borderless).help("Show in Finder")
                    }
                }
            }
            .frame(width: 380, height: 300)
            Divider()
            HStack {
                Button("Clear Finished") { model.clearFinished() }
                Spacer()
                Button("Cancel All", role: .destructive) { model.cancelAll() }.disabled(model.activeTransfer == nil)
            }
            .padding(10)
        }
    }
}

// MARK: - Helpers

func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file) }

@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func type(for item: Item) -> UTType {
        item.isFolder ? .folder : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
    }

    static func icon(for item: Item) -> NSImage {
        let t = type(for: item)
        if let i = cache[t.identifier] { return i }
        let i = NSWorkspace.shared.icon(for: t)
        cache[t.identifier] = i
        return i
    }

    static func hasThumbnail(_ item: Item) -> Bool {
        let t = type(for: item)
        return t.conforms(to: .image) || t.conforms(to: .movie)
    }

    static func kind(for item: Item) -> String { type(for: item).localizedDescription ?? "Document" }
}
