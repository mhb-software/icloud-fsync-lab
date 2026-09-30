# iCloud fsync Lab

A diagnostics app, not a product. See README.md for what it measures. The interface exists to run
the experiments and show the numbers, nothing more.

## What has been agreed

- Why it exists: Mix keeps everything in SwiftData today. The lab helps decide whether a mix should
  become a file in iCloud Drive, and if so, a `.mix` zip or a folder. The `.mix` format exists only
  as prototype export code in Mix, not in production.
- The four questions in the README, plus the comparison of storage kinds. Adding a fifth is a
  conversation, not a commit.
- Single player. Two people never edit one document at once. The conflict worth studying is the
  stale device: an edit made before the other device's edit arrived.
- Three storage kinds, chosen per document when it is created, side by side in the same container:
  a zip in the `.mix` layout, a package (a folder the app declares as a document type, so Files and
  iCloud treat it as one item), and a plain folder. The rest of the app does not know which is which.
- Writing is one choice for all three formats, so they compare like for like: replace (delete then
  create, what Mix's export writer does), swap (a complete new copy swapped into place), or in place
  (the same files written over; a zip rewrites its bytes, a package or folder only the changed files).
  Every write is coordinated.
- The document mirrors the `.mix` layout: `Info.json`, `mix.json` (a stand in description of the
  real size, plus the stamp), `preview.jpg` (about 300 KB, new on every save), and
  `resources/<sha256>.<ext>` with each photo (random bytes the size of a 2560 px HEIC) and its
  thumbnail. In the zip, JSON is compressed, images are stored, and resources are sorted by name, as
  in Mix. Mix's sample mixes run 0.8 to 7.4 MB; the photo count sets the size.
- The write rhythm is Mix's: a save on every action (a move, an edit, a photo added or removed), at
  human pace.
- The iOS and macOS 26 sync controls are part of the lab: pause sync, upload now, fetch latest now,
  resume.
- The output is a log, a results table with one row per edit (saved with write time and bytes,
  uploaded, then listed and readable on each other device), and a grid comparing Zip, Package and
  Folder for the three use cases: speed, not losing work, iCloud off and on. Readable means the
  device had the whole edit and every file matched its checksum. The sender writes a stamp
  inside the document (device, clock, edit number, the edits it contains, a checksum for every other
  file); the receiver reads it to measure. Each device keeps its own log, outside the iCloud
  container.
- The devices talk directly with Network framework and Bonjour: to send each other their times, to
  measure the clock offset, and to run tests together. While a test runs, every linked device shows
  it and can stop it; the conflict test has them all edit at the same moment.
- iCloud is turned on and off in Settings, never in the app. The app notices, logs what happened to
  the files, and keeps new documents on the device while iCloud is off.
- Documents are visible in Files and Finder.
- Native SwiftUI app for iOS, iPadOS and macOS 26 or later, so a Mac is a real peer.
- Bundle identifier `software.mhb.fsynclab`, container `iCloud.software.mhb.fsynclab`. The project
  ships with no team. Nothing shared with Mix.
- Public open source.

## Measured before this repo existed

A Mac wrote into an iCloud Drive folder and an iPhone watched in Files, 2026-09-29.

- A new 6.8 MB zip uploaded in about 5 seconds and showed on the phone within about 30.
- An edit that changed only the JSON and shifted every later byte sent about 0.1 MB. iCloud dedupes
  unchanged bytes even when they move, so a flat zip is not expensive to re-upload. That was a Mac;
  a 2018 study found iOS uploads whole files, so edits made on an iPhone need their own measurement.
- A 51 byte file took 17 seconds. Latency is the system's scheduling, not size.
- A fresh file briefly reports Cocoa error 4355 before uploading fine. The first error is not real.
- Conflicts depend on how the file was written. A file replaced by a new file became two visible
  files, the older renamed with " 2". A file edited in place stayed one file: newest wins, the loser
  kept as a hidden NSFileVersion conflict version. This was in the shared iCloud Drive folder; an
  app's own container may behave differently (Apple's TN2336), which is one thing to find out.
- iOS does not download another device's files on its own. The app has to ask.

## How to work here

- Ask before assuming. When something is unclear, ask. Discuss anything new before building it.
- Keep it simple. This is a tool for a few days of measurement, not a platform. Research lightly;
  unknowns are what the lab measures.
- Claude builds and compiles. Sam runs the experiments on devices.
- Plain English everywhere: no dashes as punctuation, American spelling.
- Conventional Commits.
