# Third-party notices

## Brave iOS (brave/brave-core)

`reference/brave-media/upstream/` contains unmodified source files from
[brave/brave-core](https://github.com/brave/brave-core) at commit
`b38bae283b5a99943d114655f76a495d901a68b0`, kept as reference material. They are licensed under the
Mozilla Public License, Version 2.0; the full text is in `reference/brave-media/upstream/LICENSE`.
`reference/brave-media/manifest.json` lists each file, its upstream path and blob hash.

Parts of the download handling in `StreamBrowser/DownloadCenter.swift` and
`StreamBrowser/SystemTransfers.swift` were written with those files as a structural reference
(see `reference/brave-media/README.md` for the per-file decisions). To the extent any of that code is
a modification of MPL-covered files, it is made available under the MPL 2.0 as well; the rest of the
Stream Browser sources are original work by the repository owner.

Stream Browser is not affiliated with or endorsed by Brave Software.
