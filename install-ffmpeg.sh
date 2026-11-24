#!/usr/bin/env bash
# Resolve an FFmpeg version requirement and install the matching precompiled
# build from the cocoa-xu/ffmpeg-build releases.
set -euo pipefail

req="${INPUT_FFMPEG_VERSION:-}"
variant="${INPUT_VARIANT:-full}"
triplet="${INPUT_TRIPLET:-}"
repo="${INPUT_REPOSITORY:-cocoa-xu/ffmpeg-build}"
install_dir="${INPUT_INSTALL_DIR:-.ffmpeg}"
add_to_path="${INPUT_ADD_TO_PATH:-true}"
token="${INPUT_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
resolve_only="${RESOLVE_ONLY:-}"

err() { echo "::error::$*" >&2; exit 1; }
log() { echo "$*" >&2; }

[ -n "$req" ] || err "ffmpeg_version input is required"
case "$variant" in
  full) archive_prefix="ffmpeg" ;;
  skeleton) archive_prefix="ffmpeg-skeleton" ;;
  *) err "variant must be 'full' or 'skeleton', got '$variant'" ;;
esac

detect_triplet() {
  local os arch a
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Linux)
      case "$arch" in
        x86_64|amd64) a=x86_64 ;;
        aarch64|arm64) a=aarch64 ;;
        *) err "unsupported Linux architecture: $arch" ;;
      esac
      if [ -f /etc/alpine-release ] || (command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl); then
        printf '%s-linux-musl' "$a"
      else
        printf '%s-linux-gnu' "$a"
      fi
      ;;
    Darwin)
      case "$arch" in
        arm64) printf 'arm64-apple-darwin' ;;
        x86_64) printf 'x86_64-apple-darwin' ;;
        *) err "unsupported macOS architecture: $arch" ;;
      esac
      ;;
    *) err "unsupported OS: $os" ;;
  esac
}

strip() { echo "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

version_valid() {
  echo "$1" | grep -Eq '^[0-9]+(\.[0-9]+)+$'
}

ver_cmp() {
  local IFS=. i max ai bi
  local -a av bv
  read -ra av <<<"$1"
  read -ra bv <<<"$2"
  max=${#av[@]}
  [ "${#bv[@]}" -gt "$max" ] && max=${#bv[@]}

  for ((i = 0; i < max; i++)); do
    ai="${av[i]:-0}"
    bi="${bv[i]:-0}"
    if ((10#$ai < 10#$bi)); then echo -1; return; fi
    if ((10#$ai > 10#$bi)); then echo 1; return; fi
  done
  echo 0
}

ver_le() { [ "$(ver_cmp "$1" "$2")" != 1 ]; }
ver_lt() { [ "$(ver_cmp "$1" "$2")" = -1 ]; }

tilde_upper() {
  local IFS=.
  local -a p
  local n
  read -ra p <<<"$1"
  n=${#p[@]}
  if [ "$n" -le 1 ]; then
    echo "$((p[0] + 1))"
  else
    p[n-2]=$((p[n-2] + 1))
    unset 'p[n-1]'
    echo "${p[*]}"
  fi
}

list_versions() {
  local auth=() page=1 body
  [ -n "$token" ] && auth=(-H "Authorization: Bearer $token")
  while :; do
    body="$(curl -fsSL "${auth[@]}" -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$repo/releases?per_page=100&page=$page" 2>/dev/null)" || break
    [ "$body" = "[]" ] || [ -z "$body" ] && break
    printf '%s' "$body" | grep -oE '"tag_name":[[:space:]]*"v?[^"]+"' \
      | sed -E 's/.*"v?([^"]+)"/\1/'
    page=$((page + 1))
    [ "$page" -gt 10 ] && break
  done | grep -E '^[0-9]+(\.[0-9]+)+$'
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

req="$(strip "$req")"
case "$req" in
  "~>"*) op="~>"; ver="$(strip "${req#\~>}")" ;;
  ">="*) op=">="; ver="$(strip "${req#>=}")" ;;
  "<="*) op="<="; ver="$(strip "${req#<=}")" ;;
  "=="*) op="=="; ver="$(strip "${req#==}")" ;;
  ">"*) op=">"; ver="$(strip "${req#>}")" ;;
  "<"*) op="<"; ver="$(strip "${req#<}")" ;;
  v[0-9]*) op="=="; ver="${req#v}" ;;
  *) op="=="; ver="$req" ;;
esac

[ -n "$ver" ] || err "could not parse version requirement: '$req'"
version_valid "$ver" || err "invalid FFmpeg version: '$ver'"

if [ -z "$triplet" ]; then
  triplet="$(detect_triplet)"
fi
archive="$archive_prefix-$triplet.tar.gz"
log "Platform: $triplet  |  variant: $variant  |  requirement: ${op} ${ver}"

asset_ok() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -I -L \
    "https://github.com/$repo/releases/download/v$1/$archive" 2>/dev/null || echo 000)"
  [ "$code" = 200 ]
}

constraint_matches() {
  local candidate="$1"
  case "$op" in
    "~>") ver_le "$ver" "$candidate" && ver_lt "$candidate" "$upper" ;;
    ">=") ver_le "$ver" "$candidate" ;;
    ">") ver_lt "$ver" "$candidate" ;;
    "<=") ver_le "$candidate" "$ver" ;;
    "<") ver_lt "$candidate" "$ver" ;;
    *) false ;;
  esac
}

resolved=""
if [ "$op" = "==" ]; then
  if asset_ok "$ver"; then
    resolved="$ver"
  else
    err "FFmpeg $ver has no $variant build for $triplet (exact match)"
  fi
else
  upper=""
  if [ "$op" = "~>" ]; then upper="$(tilde_upper "$ver")"; fi

  while read -r candidate; do
    [ -n "$candidate" ] || continue
    constraint_matches "$candidate" || continue
    if asset_ok "$candidate"; then
      if [ -z "$resolved" ] || ver_lt "$resolved" "$candidate"; then
        resolved="$candidate"
      fi
    else
      log "  (skipping $candidate - no $variant $triplet build)"
    fi
  done < <(list_versions)

  [ -n "$resolved" ] || err "no FFmpeg release satisfying '${op} ${ver}' has a $variant $triplet build"
fi

log "Resolved '${req}' -> FFmpeg ${resolved}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "ffmpeg-version=$resolved"
    echo "triplet=$triplet"
    echo "variant=$variant"
  } >> "$GITHUB_OUTPUT"
fi

[ -n "$resolve_only" ] && { echo "$resolved"; exit 0; }

mkdir -p "$install_dir"
install_dir="$(cd "$install_dir" && pwd)"
url="https://github.com/$repo/releases/download/v$resolved/$archive"

log "Downloading $url"
curl -fSL --retry 3 --retry-all-errors "$url" -o "$install_dir/$archive" \
  || err "failed to download $url"
expected="$(curl -fsSL --retry 3 --retry-all-errors "$url.sha256" | cut -d' ' -f1)" \
  || err "failed to download $url.sha256"
actual="$(sha256 "$install_dir/$archive")"
[ "$expected" = "$actual" ] || err "checksum mismatch for $archive: expected $expected, got $actual"
tar -xzf "$install_dir/$archive" -C "$install_dir"
rm -f "$install_dir/$archive"

bindir=""
[ -d "$install_dir/bin" ] && bindir="$install_dir/bin"
if [ "$add_to_path" = "true" ] && [ -n "$bindir" ] && [ -n "${GITHUB_PATH:-}" ]; then
  echo "$bindir" >> "$GITHUB_PATH"
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "FFMPEG_ROOT=$install_dir" >> "$GITHUB_ENV"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "install-dir=$install_dir"
    echo "pkg-config-path=$install_dir/lib/pkgconfig"
    echo "bindir=$bindir"
  } >> "$GITHUB_OUTPUT"
fi

log "Installed FFmpeg $resolved ($variant) into $install_dir"
