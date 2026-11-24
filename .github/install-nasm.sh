#!/usr/bin/env bash
# FFmpeg 9's x86 assembly needs a newer nasm than the 2.14 in Ubuntu 20.04.
set -euo pipefail

version=2.16.03
sha256=1412a1c760bbd05db026b6c0d1657affd6631cd0a63cddb6f73cc6d4aa616148

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
curl -fsSL --retry 3 "https://www.nasm.us/pub/nasm/releasebuilds/${version}/nasm-${version}.tar.xz" -o "${work}/nasm.tar.xz"
echo "${sha256}  ${work}/nasm.tar.xz" | sha256sum -c -
tar -xJf "${work}/nasm.tar.xz" -C "${work}"
cd "${work}/nasm-${version}"
./configure --prefix=/usr/local > /dev/null
make -j"$(nproc)" > /dev/null
make install > /dev/null
nasm -v
