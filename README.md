# Sideport

A native Apple Silicon file manager for Android phones on macOS. It replaces Google's
Android File Transfer, which is Intel-only, runs under Rosetta, and is no longer
maintained.

![Sideport](docs/screenshot.png)

## Features

- Native arm64 SwiftUI app with no Rosetta. Runs on macOS 14 Sonoma and later.
- Detects the phone automatically and reconnects when you plug it back in.
- Drag files and folders from Finder to the phone, and drag items from Sideport into Finder.
- Upload and download whole folder trees.
- Files larger than 4 GB transfer correctly. Android File Transfer could not copy them.
- Transfer bar with progress, speed and time remaining, and a Cancel All button.
- The Mac does not idle-sleep during transfers, and the Dock icon bounces when a queue finishes in the background.
- Double-click a file to open it on your Mac.
- New folder, rename and delete (with a confirmation step). Filter the current folder by name, and sort by name, size or date.
- Breadcrumb path bar, plus sidebar shortcuts to Camera, Screenshots, Downloads, Documents and Music.
- Shows internal storage and SD cards with free space, and the phone's battery level.
- Releases the phone from macOS Image Capture (`ptpcamerad`) when it holds the device. This is the most common reason "the phone is not detected".
- Hidden files are off by default. Toggle them with Cmd+Shift+.

Keyboard shortcuts: Cmd+O upload, Cmd+Shift+N new folder, Delete to delete, Cmd+Up to go to the enclosing folder, Cmd+R to refresh.

## Install

1. Download `Sideport-arm64.zip` from [Releases](https://github.com/a-kash-singh/Sideport/releases) and move `Sideport.app` to Applications.
2. The app is ad-hoc signed, not notarized. On first launch, right-click it and choose Open, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Sideport.app
   ```
3. Plug in the phone, unlock it, and choose **File transfer** in the USB notification.

## Build from source

```sh
brew install libmtp pkgconf
swift run                 # dev build, links Homebrew's libmtp
scripts/package.sh        # self-contained build/Sideport.app + zip
```

`package.sh` builds libusb and libmtp from source for macOS 14+ (pinned and checksummed),
bundles them in the app and ad-hoc signs it.

## Troubleshooting

- **Phone not detected:** unlock the phone and pick "File transfer", not "Charging only". Try another cable, because many cables carry charge only.
- **"Could not be opened":** quit other apps that talk to the phone, such as Android File Transfer, OpenMTP, Image Capture or Photos, then click Try Again.
- **Phone is locked:** Sideport waits and shows the storage once you unlock the phone.

## License

MIT. Sideport dynamically links [libmtp](https://github.com/libmtp/libmtp) and
[libusb](https://github.com/libusb/libusb), both LGPL-2.1. Their unmodified sources
are fetched by `scripts/build-deps.sh`.
