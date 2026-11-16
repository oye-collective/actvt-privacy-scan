# CZstd: zstd's decoder, vendored

The Codex desktop app compresses old sessions to `.jsonl.zst`, and macOS's Compression framework
has no zstd, so ActvtSessionParsers carries zstd's decoder itself (oye-collective/actvt-macos#53).

- **Source:** facebook/zstd, tag `v1.5.7`, commit `f8745da6ff1ad1e7bab384bd1f9d742439278e99`.
- **Licence:** BSD-3-Clause (zstd is dual BSD/GPLv2; used here under BSD). See `LICENSE`.
- **What is here:** `lib/zstd.h`, `lib/zstd_errors.h`, `lib/common/` and `lib/decompress/`, unmodified,
  in zstd's own layout so its relative includes hold. Left out: the compressor, the dictionary
  builder, the legacy-format decoders, `pool`/`threading` (multithreaded compression only) and
  `huf_decompress_amd64.S` (built with `ZSTD_DISABLE_ASM`, so Intel Macs use the C decoder).
- `module.modulemap` is ours: it exposes only the two public headers, as module `CZstd`.

To update, copy the same files from the new tag, keep the list above, and run the parser tests.
