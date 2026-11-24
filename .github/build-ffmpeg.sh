#!/usr/bin/env bash
# Build one FFmpeg release into a relocatable tarball.
#
# usage: build-ffmpeg.sh VERSION VARIANT TRIPLET OUT_DIR
#
#   full      every component FFmpeg ships (LGPL only), linked only against the
#             system zlib and iconv, plus the ffmpeg and ffprobe programs
#   skeleton  headers and shared libraries without any component, for linking
#             against whichever FFmpeg of the same major version is installed
set -euo pipefail

version="$1"
variant="$2"
triplet="$3"
mkdir -p "$4"
out_dir="$(cd "$4" && pwd)"

case "$variant" in
  full) name="ffmpeg-${triplet}" ;;
  skeleton) name="ffmpeg-skeleton-${triplet}" ;;
  *) echo "unknown variant: ${variant}" >&2; exit 1 ;;
esac

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

case "$(uname -s)" in
  Darwin)
    jobs="$(sysctl -n hw.ncpu)"
    export COPYFILE_DISABLE=1
    ;;
  *) jobs="$(nproc)" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
prefix="${work}/${name}"
src="ffmpeg-${version}"

curl -fsSL --retry 3 "https://ffmpeg.org/releases/${src}.tar.xz" -o "${work}/${src}.tar.xz"
tar -xJf "${work}/${src}.tar.xz" -C "${work}"

flags=(
  --enable-shared
  --disable-static
  --disable-doc
  --disable-autodetect
)
case "$variant" in
  full) flags+=(--disable-ffplay --enable-zlib --enable-iconv) ;;
  # FFmpeg 4.x and 5.x define avformat_get_mov_*_tags only when an ISO media format is enabled.
  skeleton) flags+=(--disable-programs --disable-everything --disable-asm --enable-demuxer=mov) ;;
esac
case "$triplet" in
  *-apple-darwin)
    flags+=(--install-name-dir=@rpath --extra-ldsoflags=-Wl,-rpath,@loader_path)
    if [ "$variant" = full ]; then
      # iconv lives in libiconv on macOS, not in libSystem.
      flags+=(--enable-videotoolbox --enable-audiotoolbox --extra-libs=-liconv --extra-ldexeflags=-Wl,-rpath,@executable_path/../lib)
    fi
    ;;
esac

cd "${work}/${src}"
./configure --prefix="${prefix}" "${flags[@]}" || { tail -n 60 ffbuild/config.log; exit 1; }
make -j"${jobs}"
make install

# Make the tree relocatable: libraries find each other in their own directory,
# programs find them in ../lib, and pkg-config derives the prefix from the .pc path.
case "$triplet" in
  *-linux-*)
    for file in "${prefix}"/lib/lib*.so.*; do
      [ -L "$file" ] || patchelf --set-rpath '$ORIGIN' "$file"
    done
    for file in "${prefix}"/bin/*; do
      [ -e "$file" ] && patchelf --set-rpath '$ORIGIN/../lib' "$file"
    done
    ;;
esac
for pc in "${prefix}"/lib/pkgconfig/*.pc; do
  sed -i.bak -E \
    -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' \
    -e 's|^exec_prefix=.*|exec_prefix=${prefix}|' \
    -e 's|^libdir=.*|libdir=${prefix}/lib|' \
    -e 's|^includedir=.*|includedir=${prefix}/include|' \
    "$pc"
  rm -f "${pc}.bak"
done

cp COPYING.LGPLv2.1 LICENSE.md "${prefix}/"
{
  echo "FFmpeg ${version}, ${variant}, ${triplet}"
  echo "source: https://ffmpeg.org/releases/${src}.tar.xz"
  echo "source sha256: $(sha256 "${work}/${src}.tar.xz")"
  echo "configure: ${flags[*]}"
  echo "compiler: $(${CC:-cc} --version | head -n 1)"
} > "${prefix}/BUILD_INFO"
cat "${prefix}/BUILD_INFO"

(cd "${prefix}" && tar -czf "${out_dir}/${name}.tar.gz" .)
(cd "${out_dir}" && echo "$(sha256 "${name}.tar.gz")  ${name}.tar.gz" > "${name}.tar.gz.sha256")
cp "${work}/${src}.tar.xz" "${out_dir}/"
ls -l "${out_dir}"

echo "::group::Check the installed tree"
if command -v pkg-config >/dev/null 2>&1; then
  export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig"
  for lib in avutil avcodec avformat swscale swresample avfilter avdevice; do
    echo "lib${lib}: $(pkg-config --modversion "lib${lib}")"
  done
  pkg-config --cflags --libs libavformat
fi
case "$triplet" in
  *-linux-*)
    for file in "${prefix}"/lib/lib*.so.* "${prefix}"/bin/*; do
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      echo "== ${file#"${prefix}"/}"
      readelf -d "$file" | grep -E 'SONAME|NEEDED|RPATH|RUNPATH'
    done
    ;;
  *-apple-darwin)
    for file in "${prefix}"/lib/lib*.dylib "${prefix}"/bin/*; do
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      echo "== ${file#"${prefix}"/}"
      otool -L "$file" | tail -n +2
      otool -l "$file" | grep -A2 LC_RPATH | grep path || true
    done
    ;;
esac
if [ -x "${prefix}/bin/ffmpeg" ]; then
  "${prefix}/bin/ffmpeg" -hide_banner -version | head -n 1
fi
echo "::endgroup::"
