#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/build/board"
PREFIX="$BUILD/wasm-deps-v2"
mkdir -p "$BUILD/sources" "$PREFIX" "$ROOT/Board/public/wasm" "$ROOT/Board/public/licenses"
fetch_source() {
  local name="$1" version="$2" checksum="$3"
  local archive="$BUILD/sources/$name-$version.tar.xz"
  if [[ ! -f "$archive" ]]; then
    curl --fail --location --retry 2 --connect-timeout 15 --max-time 180 \
      "https://ftp.gnu.org/gnu/$name/$name-$version.tar.xz" --output "$archive"
  fi
  echo "$checksum  $archive" | shasum -a 256 -c -
  if [[ ! -d "$BUILD/sources/$name-$version" ]]; then tar -xf "$archive" -C "$BUILD/sources"; fi
}
fetch_source gmp 6.3.0 a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
fetch_source mpfr 4.2.2 b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01
if [[ ! -f "$PREFIX/lib/libgmp.a" ]]; then
  mkdir -p "$BUILD/gmp-v2"
  (cd "$BUILD/gmp-v2"
   emconfigure "$BUILD/sources/gmp-6.3.0/configure" --host=none --prefix="$PREFIX" --disable-assembly --disable-shared --enable-static --disable-cxx CFLAGS="-O3 -ffile-prefix-map=$ROOT/=./" HOST_CC=/usr/bin/clang
   emmake make -j4
   emmake make install)
fi
if [[ ! -f "$PREFIX/lib/libmpfr.a" ]]; then
  mkdir -p "$BUILD/mpfr-v2"
  (cd "$BUILD/mpfr-v2"
   emconfigure "$BUILD/sources/mpfr-4.2.2/configure" --host=none --prefix="$PREFIX" --with-gmp="$PREFIX" --disable-shared --enable-static --disable-thread-safe CFLAGS="-O3 -ffile-prefix-map=$ROOT/=./"
   emmake make -j4
   emmake make install)
fi
em++ "-ffile-prefix-map=$ROOT/=./" -std=c++17 -O3 -flto -fexceptions -DMB_SINGLE_THREADED \
  "$ROOT/Sources/FractalCore/FractalCore.cpp" -I"$PREFIX/include" \
  "$PREFIX/lib/libmpfr.a" "$PREFIX/lib/libgmp.a" \
  -s MODULARIZE=1 -s EXPORT_ES6=1 -s EXPORT_NAME=createLumaModule \
  -s ENVIRONMENT=web,worker,node -s FILESYSTEM=0 -s ALLOW_MEMORY_GROWTH=1 \
  -s INITIAL_MEMORY=33554432 -s MAXIMUM_MEMORY=536870912 \
  -s DISABLE_EXCEPTION_CATCHING=0 \
  -s EXPORTED_FUNCTIONS='["_malloc","_free","_mb_viewport_create","_mb_viewport_destroy","_mb_viewport_clone","_mb_viewport_set","_mb_viewport_restore","_mb_viewport_zoom","_mb_viewport_pan","_mb_viewport_precision","_mb_viewport_log_zoom","_mb_viewport_describe","_mb_string_free","_mb_render_control_create","_mb_render_control_destroy","_mb_render_control_get_stats","_mb_render_control_set_acceleration","_mb_render","_mb_render_julia","_mb_sample_mpfr","_mb_sample_julia_mpfr"]' \
  -s EXPORTED_RUNTIME_METHODS='["ccall","UTF8ToString","HEAPF32","HEAPU8"]' \
  -o "$ROOT/Board/public/wasm/luma.js"
sed -E 's/[[:blank:]]+$//' "$BUILD/sources/gmp-6.3.0/COPYING.LESSERv3" > "$ROOT/Board/public/licenses/GMP-LGPL.txt"
sed -E 's/[[:blank:]]+$//' "$BUILD/sources/gmp-6.3.0/COPYING" > "$ROOT/Board/public/licenses/GMP-GPL.txt"
sed -E 's/[[:blank:]]+$//' "$BUILD/sources/mpfr-4.2.2/COPYING.LESSER" > "$ROOT/Board/public/licenses/MPFR-LGPL.txt"
sed -E 's/[[:blank:]]+$//' "$BUILD/sources/mpfr-4.2.2/COPYING" > "$ROOT/Board/public/licenses/MPFR-GPL.txt"
echo 'Built Board/public/wasm/luma.js and luma.wasm'
