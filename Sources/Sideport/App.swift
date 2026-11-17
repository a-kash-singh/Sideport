import SwiftUI

@main
struct SideportApp: App {
    @State private var model = AppModel()
    @AppStorage("viewMode") private var viewMode = ViewMode.list

    var body: some Scene {
        Window("Sideport", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 780, minHeight: 480)
                .task { model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Upload Files...") { model.pickUpload() }
                    .keyboardShortcut("o")
                    .disabled(model.storage == nil)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Import New Photos") { model.importNewPhotos() }
                    .keyboardShortcut("i")
                    .disabled(model.storage == nil || model.importing)
                Button("Change Import Folder...") { model.pickImportFolder() }
                Divider()
                Button("Quick Look") { model.quickLook() }
                    .keyboardShortcut("y")
                    .disabled(model.selection.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Picker("View", selection: $viewMode) {
                    Text("as List").tag(ViewMode.list).keyboardShortcut("1")
                    Text("as Thumbnails").tag(ViewMode.grid).keyboardShortcut("2")
                }
                .pickerStyle(.inline)
                Divider()
                Button("Refresh") { Task { await model.reload() } }
                    .keyboardShortcut("r")
                Toggle("Show Hidden Files", isOn: Bindable(model).showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Enclosing Folder") { model.goUp() }
                    .keyboardShortcut(.upArrow)
                    .disabled(model.path.isEmpty)
                Divider()
                ForEach(Shortcut.all) { s in
                    Button(s.title) { Task { await model.jump(to: s.paths) } }
                        .disabled(model.storage == nil)
                }
            }
        }
    }
}

extension AppModel {
    func pickUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Upload"
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    func pickDownload(_ ids: Set<Item.ID>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        if panel.runModal() == .OK, let dir = panel.url { download(ids, to: dir) }
    }
}

struct Shortcut: Identifiable {
    let title: String
    let icon: String
    let paths: [[String]]
    var id: String { title }

    static let all = [
        Shortcut(title: "Camera", icon: "camera", paths: [["DCIM", "Camera"], ["DCIM"]]),
        Shortcut(title: "Screenshots", icon: "camera.viewfinder", paths: [["Pictures", "Screenshots"], ["DCIM", "Screenshots"]]),
        Shortcut(title: "Downloads", icon: "arrow.down.circle", paths: [["Download"], ["Downloads"]]),
        Shortcut(title: "Documents", icon: "doc", paths: [["Documents"]]),
        Shortcut(title: "Music", icon: "music.note", paths: [["Music"]]),
    ]
}
