# iCloud fsync Lab

A small app that measures how iCloud Drive moves an app's documents between an iPhone, an iPad and
a Mac. Run it on two or more of your own devices. One saves documents into its iCloud container,
the others report when each save arrives and whether it arrived whole. It is a diagnostics tool,
not a product.

## What it measures

Before an app stores its documents as files in iCloud Drive, it needs answers that Apple's
documentation does not give:

- **Sync time.** After a save on one device, how long until another device lists the new version,
  and how long until it can read it.
- **Storage form.** The same document as one zip file, as a package (a folder shown as a single item
  in Files), and as a plain folder, side by side under the same conditions.
- **Write method.** Delete and recreate, write a copy and swap it in, or write over the existing
  files. iCloud handles each differently, especially on conflict.
- **Conflicts.** One person, two devices, and an edit made before the other device's edit arrived.
  Nothing may be lost silently.
- **The iCloud switch.** What happens to documents when iCloud Drive is turned off for the app, or
  turned on with documents already present.

It also tries the iOS and macOS 26 sync controls: pause, upload now, and fetch latest now.

## How it works

Each test document imitates a photo collage: a small JSON file that changes on every save, a
preview image that changes with it, and photo sized files that never change. Every save writes a
stamp naming the device, the edit number and a checksum of every other file. The receiving device
reads the stamp to know what arrived and whether every file matched.

The devices find each other on the local network and talk directly, without iCloud, to compare
clocks and to run tests together. Each device keeps its own log outside the iCloud container.

You get a timestamped log, a results table with one row per edit, and a grid comparing Zip, Package
and Folder on speed, not losing work, and surviving the iCloud switch. Save logs on the Log screen
writes all of it to a folder you choose.

## Running it

You need Xcode 26 or later, two or more devices on iOS, iPadOS or macOS 26 or later, and an Apple
developer account with iCloud.

1. Open `FsyncLab.xcodeproj`, select the FsyncLab target, and choose your team under Signing &
   Capabilities. Do not commit the team into the project file.
2. Change the bundle identifier to one you own. The iCloud container is `iCloud.` plus the bundle
   identifier. Change the matching key under `NSUbiquitousContainers` in `FsyncLab/Info.plist` too,
   since Xcode does not update the plist for you.
3. In the iCloud capability, add that container, or tick it if it is listed. Container identifiers
   can never be deleted from an account, so name it with care.
4. Run on two or more devices on the same Wi-Fi and allow local network access when asked.

Documents appear in Files and Finder under fsync Lab. During a run, keep the app open and the
screen on. A suspended app sees nothing arrive.

## Status

First build, not yet run on devices.

## Why

Built while planning multi device support for [Mix](https://mix.photos), a photo, collage and design app, to
decide whether its collages should become files in iCloud Drive and in what form. It contains no
Mix code.

## License

MIT. See LICENSE.
