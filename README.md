# iCloud fsync Lab

A diagnostics app for iCloud Drive document sync on iPhone, iPad and Mac. It answers, with numbers
from real devices, the questions an app faces before it trusts iCloud Drive to carry its documents
between a person's devices:

- **Latency, from either device as the sender.** When a document is saved on one device, how long
  until another device lists it, and how long until it can read it.
- **A realistic write pattern.** A save on every action, at the pace of a person editing, on a
  document shaped like a real one: a small description that changes on every save, a preview that
  changes with it, and photo sized blobs that never change, with one added or removed now and then.
- **Conflicts, single player style.** An edit made on a device that has not yet received the other
  device's edit. Nothing may be lost silently.
- **The iCloud switch.** What happens to documents when iCloud is turned off for the app, or turned
  on with documents already present.
- **Zip, package or folder.** The same document stored as one zip file, as a package, and as a plain
  folder, side by side under the same conditions, each with its own ways of writing.

It also tries the sync controls added in iOS and macOS 26: pausing sync while a document is open,
uploading now, and fetching the latest version now.

Status: first build. Not yet run on devices.

## Running it

You need Xcode 26 or later, devices on iOS, iPadOS or macOS 26 or later, and an Apple developer
account with iCloud.

1. Open `FsyncLab.xcodeproj`. In the FsyncLab target's Signing & Capabilities, choose your team.
2. If you are not the author, change the bundle identifier to one of your own. The iCloud container
   is `iCloud.` plus the bundle identifier. Change the matching key under `NSUbiquitousContainers`
   in `FsyncLab/Info.plist` too; Xcode does not fill in a plist key for you.
3. In the iCloud capability, add that container with the + button, or tick it if it is listed.
   Container identifiers can never be removed from an account, so choose deliberately.
4. Build to two devices on the same Wi-Fi. Allow local network access when asked; that is how the
   two copies send each other their timings.

Documents show in Files and Finder under fsync Lab once the first one exists. During a run keep
both apps open with the screen on: iOS pauses apps in the background, and a paused app sees nothing.

## Why

Built while planning multi device support for [Mix](https://mix.photos), a photo collage app for
iPhone and iPad. This is not Mix code and borrows nothing from it.

## License

MIT. See LICENSE.
