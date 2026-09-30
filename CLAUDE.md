# iCloud Sync Lab

A diagnostics app, not a product. See README.md for what it measures. The interface exists to run
the experiments and show the numbers, nothing more.

## What has been agreed

- The four questions in the README, plus the zip versus folder comparison. Adding a fifth is a
  conversation, not a commit.
- Single player. Two people never edit one document at once. The conflict worth studying is the
  stale device: an edit made before the other device's edit arrived.
- One document abstraction with two storage backends, zip and folder, chosen per document when it
  is created. Both kinds live side by side in the same iCloud container and the rest of the app does
  not know which is which. Each backend offers its own list of write styles (swap a temp file into
  place, overwrite in place, delete then create, and for folders, rewrite only the changed files).
- The document: a small JSON description that changes on every save, a preview blob that changes
  with it, and several large blobs of random bytes standing in for photos that never change, with
  one added now and then. Five to thirty megabytes in all.
- Native SwiftUI app for iOS, iPadOS and macOS, so a Mac is a real peer.
- The output is a log and a results table with one row per edit: saved, uploaded, listed on the
  other device, readable on the other device. The sender writes a stamp inside the document (its
  own clock and edit number); the receiver reads it to measure. Each device keeps its own log,
  outside the iCloud container.
- Own bundle identifier and container identifier, as one setting. Nothing shared with Mix.
- Public open source.

## Measured before this repo existed

A Mac wrote into an iCloud Drive folder and an iPhone watched in Files, 2026-09-29.

- A new 6.8 MB zip uploaded in about 5 seconds and showed on the phone within about 30.
- An edit that changed only the JSON and shifted every later byte sent about 0.1 MB. iCloud dedupes
  unchanged bytes even when they move, so a flat zip is not expensive to re-upload.
- A 51 byte file took 17 seconds. Latency is the system's scheduling, not size.
- A fresh file briefly reports Cocoa error 4355 before uploading fine. The first error is not real.
- Conflicts depend on how the file was written. A file replaced by a new file became two visible
  files, the older renamed with " 2". A file edited in place stayed one file: newest wins, the loser
  kept as a hidden NSFileVersion conflict version. This was in the shared iCloud Drive folder; an
  app's own container may behave differently (Apple's TN2336), which is one thing to find out.
- iOS does not download another device's files on its own. The app has to ask.

## How to work here

- Ask before assuming. When something is unclear, ask. Discuss anything new before building it.
- Keep it simple. This is a tool for a few days of measurement, not a platform.
- Plain English everywhere: no dashes as punctuation, American spelling.
- Conventional Commits.
