import CMTP
import Foundation

enum MTPError: LocalizedError {
    case noDevice, busy, cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: "No Android device found."
        case .busy: "The device is connected but could not be opened. Unlock it and choose \"File transfer\" in the USB notification."
        case .cancelled: "Cancelled."
        case .failed(let m): m
        }
    }
}

struct DeviceInfo: Sendable {
    var name: String
    var model: String
    var manufacturer: String
}

struct Storage: Identifiable, Hashable, Sendable {
    let id: UInt32
    let name: String
    let capacity: UInt64
    let free: UInt64
}

struct Item: Identifiable, Hashable, Sendable {
    let id: UInt32
    let storage: UInt32
    let name: String
    let size: UInt64
    let modified: Date
    let isFolder: Bool
}

/// Root folder id for listing (libmtp uses 0 for root when creating/sending).
let rootFolder: UInt32 = 0xFFFF_FFFF

/// Progress + cancel flag handed to libmtp's C callback. Progress is throttled and delivered on main.
final class TransferToken: @unchecked Sendable {
    var cancelled = false
    var onProgress: @MainActor (UInt64, UInt64) -> Void = { _, _ in }
    private var last = Date.distantPast

    func report(_ sent: UInt64, _ total: UInt64) {
        let now = Date()
        guard sent == total || now.timeIntervalSince(last) > 0.1 else { return }
        last = now
        let cb = onProgress
        DispatchQueue.main.async { MainActor.assumeIsolated { cb(sent, total) } }
    }
}

private let progressCallback: LIBMTP_progressfunc_t = { sent, total, data in
    let token = Unmanaged<TransferToken>.fromOpaque(data!).takeUnretainedValue()
    token.report(sent, total)
    return token.cancelled ? 1 : 0
}

/// Thin wrapper over libmtp. libmtp is not thread-safe, so every call goes through one serial queue via `run`.
final class MTPDevice: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sideport.mtp")
    private var dev: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?

    init() { LIBMTP_Init() }

    func run<T>(_ body: @escaping (MTPDevice) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async { c.resume(with: Result { try body(self) }) }
        }
    }

    // MARK: everything below runs on `queue`

    func open() throws -> DeviceInfo {
        close()
        var raw: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let err = LIBMTP_Detect_Raw_Devices(&raw, &count)
        defer { free(raw) }
        guard err == LIBMTP_ERROR_NONE, count > 0, let raw else { throw MTPError.noDevice }
        guard let d = LIBMTP_Open_Raw_Device_Uncached(raw) else { throw MTPError.busy }
        dev = d
        let model = take(LIBMTP_Get_Modelname(d)) ?? "Android device"
        return DeviceInfo(
            name: take(LIBMTP_Get_Friendlyname(d)) ?? model,
            model: model,
            manufacturer: take(LIBMTP_Get_Manufacturername(d)) ?? ""
        )
    }

    func close() {
        if let dev { LIBMTP_Release_Device(dev) }
        dev = nil
    }

    func storages() throws -> [Storage] {
        let d = try handle()
        guard LIBMTP_Get_Storage(d, 0) == 0 else { throw failure("Could not read storage") }
        var out: [Storage] = []
        var s = d.pointee.storage
        while let p = s {
            let v = p.pointee
            out.append(Storage(id: v.id, name: v.StorageDescription.map { String(cString: $0) } ?? "Storage",
                               capacity: v.MaxCapacity, free: v.FreeSpaceInBytes))
            s = v.next
        }
        return out
    }

    func battery() -> Int? {
        guard let dev else { return nil }
        var max: UInt8 = 0, cur: UInt8 = 0
        guard LIBMTP_Get_Batterylevel(dev, &max, &cur) == 0, max > 0 else {
            LIBMTP_Clear_Errorstack(dev)
            return nil
        }
        return Int(cur) * 100 / Int(max)
    }

    func list(storage: UInt32, parent: UInt32) throws -> [Item] {
        let d = try handle()
        var out: [Item] = []
        var f = LIBMTP_Get_Files_And_Folders(d, storage, parent)
        // An empty folder also returns NULL; only the error stack tells them apart.
        if f == nil, LIBMTP_Get_Errorstack(d) != nil { throw failure("Could not list folder") }
        while let p = f {
            let v = p.pointee
            out.append(Item(id: v.item_id, storage: v.storage_id,
                            name: v.filename.map { String(cString: $0) } ?? "?",
                            size: v.filesize,
                            modified: Date(timeIntervalSince1970: TimeInterval(v.modificationdate)),
                            isFolder: v.filetype == LIBMTP_FILETYPE_FOLDER))
            f = v.next
            LIBMTP_destroy_file_t(p)
        }
        return out
    }

    /// The small JPEG preview the phone keeps for photos and videos. nil when there is none.
    func thumbnail(_ id: UInt32) -> Data? {
        guard let dev else { return nil }
        var data: UnsafeMutablePointer<UInt8>?
        var size: UInt32 = 0
        defer { free(data) }
        guard LIBMTP_Get_Thumbnail(dev, id, &data, &size) == 0, let data, size > 0 else {
            LIBMTP_Clear_Errorstack(dev)
            return nil
        }
        return Data(bytes: data, count: Int(size))
    }

    func download(_ id: UInt32, to url: URL, token: TransferToken) throws {
        let d = try handle()
        let r = LIBMTP_Get_File_To_File(d, id, url.path, progressCallback, Unmanaged.passUnretained(token).toOpaque())
        if r != 0 {
            try? FileManager.default.removeItem(at: url)
            throw token.cancelled ? MTPError.cancelled : failure("Download failed")
        }
    }

    func upload(_ url: URL, name: String, size: UInt64, parent: UInt32, storage: UInt32, token: TransferToken) throws {
        let d = try handle()
        guard let f = LIBMTP_new_file_t() else { throw MTPError.failed("Out of memory") }
        defer { LIBMTP_destroy_file_t(f) }  // also frees filename
        f.pointee.filename = strdup(name)
        f.pointee.filesize = size
        f.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
        f.pointee.parent_id = parent == rootFolder ? 0 : parent
        f.pointee.storage_id = storage
        let r = LIBMTP_Send_File_From_File(d, url.path, f, progressCallback, Unmanaged.passUnretained(token).toOpaque())
        if r != 0 { throw token.cancelled ? MTPError.cancelled : failure("Upload failed") }
    }

    func createFolder(_ name: String, parent: UInt32, storage: UInt32) throws -> UInt32 {
        let d = try handle()
        let id = name.withCString { LIBMTP_Create_Folder(d, UnsafeMutablePointer(mutating: $0), parent == rootFolder ? 0 : parent, storage) }
        guard id != 0 else { throw failure("Could not create folder") }
        return id
    }

    func delete(_ id: UInt32) throws {
        let d = try handle()
        guard LIBMTP_Delete_Object(d, id) == 0 else { throw failure("Could not delete") }
    }

    func rename(_ id: UInt32, to name: String) throws {
        let d = try handle()
        let r = name.withCString { LIBMTP_Set_Object_Filename(d, id, UnsafeMutablePointer(mutating: $0)) }
        guard r == 0 else { throw failure("Could not rename") }
    }

    // MARK: helpers

    private func handle() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let dev else { throw MTPError.noDevice }
        return dev
    }

    private func failure(_ what: String) -> MTPError {
        guard let dev else { return .noDevice }
        var msg = what
        var e = LIBMTP_Get_Errorstack(dev)
        while let p = e {
            if p.pointee.next == nil, let t = p.pointee.error_text { msg += ": " + String(cString: t) }
            e = p.pointee.next
        }
        LIBMTP_Clear_Errorstack(dev)
        return .failed(msg)
    }

    private func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { free(p) }
        let s = String(cString: p)
        return s.isEmpty ? nil : s
    }
}
