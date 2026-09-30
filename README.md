# iCloud fsync Lab

A diagnostics app for iCloud Drive document sync on iPhone, iPad and Mac. It answers, with numbers
from real devices, the questions an app faces before it trusts iCloud Drive to carry its documents
between a person's devices:

- **Latency, from either device as the sender.** When a document is saved on one device, how long
  until another device lists it, and how long until it can read it.
- **A realistic write pattern.** Bursts of saves at the rhythm of an editing session, on a document
  shaped like a real one: a small description that changes on every save, a preview that changes
  with it, and photo sized blobs that never change.
- **Conflicts, single player style.** An edit made on a device that has not yet received the other
  device's edit. Nothing may be lost silently.
- **The iCloud switch.** What happens to documents when iCloud is turned off for the app, or turned
  on with documents already present.
- **Zip versus folder.** The same document stored as one zip file and as a folder of files, side by
  side under the same conditions.

Status: planning. Nothing is built yet.

## Running it

You need an Apple developer account with iCloud enabled. Set your own bundle identifier and team.
The iCloud container is `iCloud.` plus the bundle identifier, and it is registered on your account
the first time you build to a device. Container identifiers cannot be removed from an account
afterward, so choose it deliberately.

## Why

Built while planning multi device support for [Mix](https://mix.photos), a photo collage app for
iPhone and iPad. This is not Mix code and borrows nothing from it.

## License

MIT. See LICENSE.
