# ffmpeg-build

[![Sponsor cocoa-xu](https://img.shields.io/github/sponsors/cocoa-xu?label=Sponsor&logo=github&color=ea4aaa)](https://github.com/sponsors/cocoa-xu)

Precompiled FFmpeg for NIF library CI builds.

## Builds

Each release `vX.Y.Z` holds two archives per platform:

- `ffmpeg-<triplet>.tar.gz`: every component FFmpeg ships, LGPL only (no `--enable-gpl`, no `--enable-nonfree`). It links only against the system zlib and iconv, plus VideoToolbox and AudioToolbox on macOS, and includes the `ffmpeg` and `ffprobe` programs.
- `ffmpeg-skeleton-<triplet>.tar.gz`: headers and shared libraries without components (`--disable-everything`). Link against it at build time, then load whichever FFmpeg of the same major version the system has at runtime: the libraries carry the same sonames, such as `libavcodec.so.61`. It keeps the mov demuxer, because FFmpeg 4.x and 5.x only define `avformat_get_mov_*_tags` when an ISO media format is enabled.

Each archive contains `include/`, `lib/` and, for full builds, `bin/`. The tree is relocatable:

- `pkg-config` files derive their prefix from their own location.
- Libraries find each other through `$ORIGIN` on Linux, and through `@loader_path` on macOS, where install names are `@rpath/libavcodec.61.dylib`.

| Triplet | Built on |
| --- | --- |
| `x86_64-linux-gnu` | `ubuntu:20.04` (glibc 2.31) |
| `aarch64-linux-gnu` | `ubuntu:20.04` (glibc 2.31) |
| `x86_64-linux-musl` | `alpine:3.18` (musl 1.2.4) |
| `aarch64-linux-musl` | `alpine:3.18` (musl 1.2.4) |
| `arm64-apple-darwin` | macOS 15, deployment target 11.0 |
| `x86_64-apple-darwin` | macOS 15, deployment target 11.0 |

Pushing a tag `vX.Y.Z` builds and publishes that FFmpeg version.

## GitHub Action

```yaml
- uses: cocoa-xu/ffmpeg-build@main
  id: ffmpeg
  with:
    ffmpeg_version: "~> 9.0"   # or an exact version such as "9.0.2"
    variant: skeleton          # or full (the default)
    install-dir: .ffmpeg

- run: pkg-config --cflags --libs libavformat
  env:
    PKG_CONFIG_PATH: ${{ steps.ffmpeg.outputs.pkg-config-path }}
```

The archive is verified against its `.sha256` before it is extracted. Outputs:

- `ffmpeg-version`: the resolved version.
- `install-dir`
- `pkg-config-path`
- `bindir`: added to `PATH` for full builds.
- `triplet`
- `variant`

## License

The build scripts are licensed under Apache-2.0. FFmpeg is licensed under LGPL-2.1-or-later:

- Every archive carries FFmpeg's `COPYING.LGPLv2.1` and `LICENSE.md`, and a `BUILD_INFO` file with the configure flags.
- Every release includes the FFmpeg source tarball it was built from.
