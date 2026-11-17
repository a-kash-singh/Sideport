import AppKit
import Observation
import UniformTypeIdentifiers

@Observable @MainActor
final class Transfer: Identifiable {
    enum Kind { case upload, download }
    enum State: Equatable { case running, done, cancelled, failed(String) }

    let id = UUID()
    let name: String
    let kind: Kind
    var sent: UInt64 = 0
    var total: UInt64
    var state: State = .running
    let started = Date()
    var localURL: URL?
    let token = TransferToken()

    init(name: String, kind: Kind, total: UInt64) {
        self.name = name
        self.kind = kind
        self.total = total
        token.onProgress = { [weak self] s, t in self?.sent = s; self?.total = t }
    }

    var fraction: Double { total == 0 ? 0 : Double(sent) / Double(total) }
}

@Observable @MainActor
final class AppModel {
    enum Status: Equatable { case searching, connected, failed(String) }

    var status = Status.searching
    var device: DeviceInfo?
    var battery: Int?
    var storages: [Storage] = []
    private(set) var storage: Storage.ID?
    private(set) var path: [Item] = []
    private(set) var items: [Item] = []
    var loading = false
    var showHidden = false
    var filter = ""
    var transfers: [Transfer] = []
    var errorMessage: String?

    let mtp = MTPDevice()
    private var started = false
    private var releasedImageCapture = false
    private var queueTail: Task<Void, Never>?
    private var pendingJobs = 0
    private var generation = 0

    var currentFolder: UInt32 { path.last?.id ?? rootFolder }
    var currentStorage: Storage? { storages.first { $0.id == storage } }
    var activeTransfer: Transfer? { transfers.last { $0.state == .running } }
    var isBusy: Bool { pendingJobs > 0 }

    var visibleItems: [Item] {
        items.filter {
            (showHidden || !$0.name.hasPrefix("."))
                && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter))
        }
    }

    // MARK: connection

    func start() {
        guard !started else { return }
        started = true
        Task {
            while true {
                await tick()
                try? await Task.sleep(for: .seconds(device == nil ? 2 : 4))
            }
        }
    }

    private func tick() async {
        guard device != nil else { return await connect() }
        // Heartbeat: refresh free space / battery, and notice unplugging.
        do {
            let (s, b) = try await mtp.run { (try $0.storages(), $0.battery()) }
            battery = b
            if s.map(\.id) != storages.map(\.id) {
                storages = s
                if storage == nil || !s.contains(where: { $0.id == storage }) { select(storage: s.first?.id) }
            } else {
                storages = s
            }
        } catch {
            await disconnected()
        }
    }

    func connect() async {
        do {
            let info = try await mtp.run { try $0.open() }
            device = info
            status = .connected
            await tick()
        } catch MTPError.busy {
            // macOS's Image Capture agent (ptpcamerad) often claims Android phones first. Release it once and retry.
            if !releasedImageCapture {
                releasedImageCapture = true
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                p.arguments = ["ptpcamerad"]
                try? p.run()
                p.waitUntilExit()
                return await connect()
            }
            status = .failed(MTPError.busy.localizedDescription)
        } catch {
            status = .searching
        }
    }

    private func disconnected() async {
        _ = try? await mtp.run { $0.close() }
        for t in transfers where t.state == .running { t.token.cancelled = true }
        generation += 1
        device = nil
        battery = nil
        storages = []
        storage = nil
        path = []
        items = []
        releasedImageCapture = false
        status = .searching
    }

    // MARK: navigation

    func select(storage id: Storage.ID?) {
        guard id != storage else { return }
        storage = id
        path = []
        items = []
        Task { await reload() }
    }

    func open(_ item: Item) {
        if item.isFolder {
            path.append(item)
            items = []
            filter = ""
            Task { await reload() }
        } else {
            let dir = FileManager.default.temporaryDirectory.appending(path: "Sideport/\(UUID().uuidString)")
            schedule { [self] in
                if let url = try? await fetch(item, into: dir) { NSWorkspace.shared.open(url) }
            }
        }
    }

    func go(toDepth depth: Int) {
        guard depth < path.count else { return }
        path.removeSubrange(depth...)
        items = []
        Task { await reload() }
    }

    func goUp() { go(toDepth: max(path.count - 1, 0)) }

    /// Jump to the first folder path (by names from the storage root) that exists.
    func jump(to candidates: [[String]]) async {
        guard let s = storage else { return }
        for names in candidates {
            var trail: [Item] = []
            var parent = rootFolder
            for name in names {
                guard let kids = try? await mtp.run({ try $0.list(storage: s, parent: parent) }),
                      let hit = kids.first(where: { $0.isFolder && $0.name.caseInsensitiveCompare(name) == .orderedSame })
                else { trail = []; break }
                trail.append(hit)
                parent = hit.id
            }
            if !trail.isEmpty {
                path = trail
                filter = ""
                await reload()
                return
            }
        }
        errorMessage = "That folder was not found on this device."
    }

    func reload() async {
        guard let s = storage else { items = []; return }
        let parent = currentFolder
        loading = true
        defer { loading = false }
        do {
            let r = try await mtp.run { try $0.list(storage: s, parent: parent) }
            if parent == currentFolder, s == storage { items = r }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: file operations

    func createFolder(named name: String) {
        guard let s = storage, !name.isEmpty else { return }
        let parent = currentFolder
        schedule { [self] in
            do { _ = try await mtp.run { try $0.createFolder(name, parent: parent, storage: s) } }
            catch { errorMessage = error.localizedDescription }
            await reload()
        }
    }

    func rename(_ item: Item, to name: String) {
        guard !name.isEmpty, name != item.name else { return }
        schedule { [self] in
            do { try await mtp.run { try $0.rename(item.id, to: name) } }
            catch { errorMessage = error.localizedDescription }
            await reload()
        }
    }

    func delete(_ ids: Set<Item.ID>) {
        let targets = items.filter { ids.contains($0.id) }
        schedule { [self] in
            for item in targets {
                do { try await mtp.run { try $0.delete(item.id) } }
                catch { errorMessage = "\(item.name): \(error.localizedDescription)"; break }
            }
            await reload()
        }
    }

    func download(_ ids: Set<Item.ID>, to dir: URL) {
        for item in items where ids.contains(item.id) {
            schedule { [self] in
                if let url = try? await fetch(item, into: dir) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    func upload(_ urls: [URL]) {
        guard let s = storage else { return }
        let parent = currentFolder
        var taken = Set(items.map(\.name))
        for url in urls {
            let name = uniqueName(url.lastPathComponent, taken: taken)
            taken.insert(name)
            schedule { [self] in try? await send(url, as: name, parent: parent, storage: s) }
        }
        schedule { [self] in await reload() }
    }

    /// Drag-out support: Finder asks for the file, we download it to a temp folder and hand it over.
    func itemProvider(for item: Item) -> NSItemProvider {
        let p = NSItemProvider()
        p.suggestedName = item.name
        let type = item.isFolder ? UTType.folder : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
        p.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            Task { @MainActor in
                let dir = FileManager.default.temporaryDirectory.appending(path: "Sideport/\(UUID().uuidString)")
                self.schedule {
                    do { done(try await self.fetch(item, into: dir), false, nil) }
                    catch { done(nil, false, error) }
                }
            }
            return nil
        }
        return p
    }

    func cancelAll() {
        generation += 1
        for t in transfers where t.state == .running { t.token.cancelled = true }
    }

    func clearFinished() { transfers.removeAll { $0.state != .running } }

    // MARK: transfer engine

    /// Runs jobs one after another; cancelAll() skips jobs that were queued before it.
    private func schedule(_ job: @escaping @MainActor () async -> Void) {
        let prev = queueTail
        let gen = generation
        pendingJobs += 1
        queueTail = Task { @MainActor in
            await prev?.value
            if gen == generation { await job() }
            pendingJobs -= 1
            if pendingJobs == 0, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    /// Download a file, or a folder tree, into `dir`. One Transfer row per file.
    private func fetch(_ item: Item, into dir: URL) async throws -> URL {
        let gen = generation
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = uniqueURL(dir.appending(path: item.name))
        if item.isFolder {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for kid in try await mtp.run({ try $0.list(storage: item.storage, parent: item.id) }) {
                guard gen == generation else { throw MTPError.cancelled }
                _ = try await fetch(kid, into: dest)
            }
        } else {
            let t = Transfer(name: item.name, kind: .download, total: item.size)
            try await perform(t) { try $0.download(item.id, to: dest, token: $1) }
            t.localURL = dest
        }
        return dest
    }

    /// Upload a file, or a folder tree, into `parent`.
    private func send(_ url: URL, as name: String, parent: UInt32, storage: UInt32) async throws {
        let gen = generation
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values.isDirectory == true {
            let id = try await mtp.run { try $0.createFolder(name, parent: parent, storage: storage) }
            let kids = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            for kid in kids {
                guard gen == generation else { throw MTPError.cancelled }
                try await send(kid, as: kid.lastPathComponent, parent: id, storage: storage)
            }
        } else {
            let size = UInt64(values.fileSize ?? 0)
            let t = Transfer(name: name, kind: .upload, total: size)
            try await perform(t) { try $0.upload(url, name: name, size: size, parent: parent, storage: storage, token: $1) }
        }
    }

    private func perform(_ t: Transfer, _ body: @escaping (MTPDevice, TransferToken) throws -> Void) async throws {
        transfers.append(t)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Transferring files")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let token = t.token
        do {
            try await mtp.run { try body($0, token) }
            t.sent = t.total
            t.state = .done
        } catch {
            t.state = token.cancelled ? .cancelled : .failed(error.localizedDescription)
            if !token.cancelled { errorMessage = "\(t.name): \(error.localizedDescription)" }
            throw error
        }
    }
}

func uniqueName(_ name: String, taken: Set<String>) -> String {
    guard taken.contains(name) else { return name }
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var n = 2
    while true {
        let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        if !taken.contains(candidate) { return candidate }
        n += 1
    }
}

func uniqueURL(_ url: URL) -> URL {
    let dir = url.deletingLastPathComponent()
    let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    return dir.appending(path: uniqueName(url.lastPathComponent, taken: taken))
}
