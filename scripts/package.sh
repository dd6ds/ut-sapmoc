#!/usr/bin/env bash
# Assemble the click directory and, when run on its own, build the .click.
# Called by scripts/build-comaps.sh with COMAPS_BIN set to the built binary.
#   $1 = target directory (clickable's install dir). Without it the click is
#        assembled in build/click and packed with "click build".
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="source/comaps"
BIN="${COMAPS_BIN:?COMAPS_BIN not set}"
CLICK_DIR="${1:-build/click}"
STANDALONE=0
[ -z "${1:-}" ] && STANDALONE=1
VERSION="${COMAPS_VERSION:-0.1.0}"
ARCH="${CLICK_ARCH:-arm64}"
FRAMEWORK="${COMAPS_FRAMEWORK:-ubuntu-touch-26.04-1.x}"

echo "[ut-sapmoc] Assembling click directory in $CLICK_DIR ..."
rm -rf "$CLICK_DIR"
mkdir -p "$CLICK_DIR/lib" "$CLICK_DIR/data"

# --- Click metadata and hooks (all paths are relative to the click root) -----
sed -e "s/@CLICK_VERSION@/$VERSION/" \
    -e "s/@CLICK_ARCH@/$ARCH/" \
    -e "s/@CLICK_FRAMEWORK@/$FRAMEWORK/" \
    manifest.in.json > "$CLICK_DIR/manifest.json"
cp ut-sapmoc.desktop ut-sapmoc.apparmor icons/ut-sapmoc.svg "$CLICK_DIR/"
install -m 755 launch/ut-sapmoc "$CLICK_DIR/ut-sapmoc"
# The 2404.x AppArmor profile forbids exec of /usr/bin/*; the launcher needs
# mkdir, so ship coreutils' mkdir inside the click (exec there is allowed).
install -D -m 755 "$(command -v mkdir)" "$CLICK_DIR/bin/mkdir"
install -m 755 "$BIN" "$CLICK_DIR/ut-sapmoc.bin"

# --- App resources (drules, fonts, symbols, classificator, World.mwm, ...) ---
# Trim folders the app does not need. test_data only serves CoMaps' unit tests
# (its file names with non-ASCII characters also fail the OpenStore review).
EXCLUDES="${COMAPS_DATA_EXCLUDE:-test_data}"
echo "[ut-sapmoc] Copying app data from $SRC/data ..."
rsync -a --delete \
    $(for e in ${EXCLUDES//:/ }; do echo "--exclude=$e"; done) \
    "$SRC/data/" "$CLICK_DIR/data/"

# Translated place types ("Großstadt" instead of "City") for search results and
# the place page: the iPhone app's strings, read by GetLocalizedTypeName.
mkdir -p "$CLICK_DIR/data/ut-types"
for f in "$SRC"/iphone/Maps/LocalizedStrings/*.lproj/LocalizableTypes.strings; do
    [ -f "$f" ] || continue
    lang="$(basename "$(dirname "$f")" .lproj)"
    cp "$f" "$CLICK_DIR/data/ut-types/$lang.strings"
done

# Pico voices for the spoken turn instructions (libttspico-data).
PICO_LANG="${PICO_LANG_DIR:-/usr/share/pico/lang}"
if [ -d "$PICO_LANG" ]; then
    mkdir -p "$CLICK_DIR/data/ut-pico"
    cp -L "$PICO_LANG"/*.bin "$CLICK_DIR/data/ut-pico/"
else
    echo "[ut-sapmoc] WARNING: $PICO_LANG missing - no voice instructions." >&2
fi

# Qt's own texts (OK/Cancel, file dialog ...) in the user's language.
QT_TR="${QT_TRANSLATIONS_DIR:-/usr/share/qt6/translations}"
if ls "$QT_TR"/qtbase_*.qm >/dev/null 2>&1; then
    mkdir -p "$CLICK_DIR/data/ut-qt-translations"
    cp -L "$QT_TR"/qtbase_*.qm "$CLICK_DIR/data/ut-qt-translations/"
else
    echo "[ut-sapmoc] WARNING: no Qt translations in $QT_TR." >&2
fi

# --- Runtime libraries ----------------------------------------------------------
# The app uses the phone's Qt 6.10 and its plugins (Wayland, Maliit keyboard,
# lomiri position source): the OpenStore only accepts the Qt of the Ubuntu Touch
# framework. Bundled are only the libraries the phone lacks, judged by the list
# of libraries on a UT 26.04 phone (scripts/ut-26.04-arm64-libs.txt; refresh with
#   adb shell "ls -1 /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu /usr/lib | grep '\.so' | sort -u").
SYSTEM_LIBS="${UT_SYSTEM_LIBS:-scripts/ut-26.04-arm64-libs.txt}"
declare -A ON_PHONE=()
while read -r l; do [ -n "$l" ] && ON_PHONE[$l]=1; done < "$SYSTEM_LIBS"
is_system_lib() {
    local name
    name="$(basename "$1")"
    case "$name" in
        ld-linux*|libc.so*|libm.so*|libdl.so*|librt.so*|libpthread.so*) return 0 ;;
    esac
    [ -n "${ON_PHONE[$name]:-}" ]
}
declare -A SEEN=()
copy_libs() {
    local lib
    for lib in $(ldd "$@" 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// {print $3}' | sort -u); do
        [ -n "${SEEN[$lib]:-}" ] && continue
        SEEN[$lib]=1
        is_system_lib "$lib" && continue
        echo "[ut-sapmoc]   bundling $(basename "$lib")"
        cp -Ln "$lib" "$CLICK_DIR/lib/"
        copy_libs "$lib"
    done
}
echo "[ut-sapmoc] Bundling shared libraries the phone lacks ..."
copy_libs "$CLICK_DIR/ut-sapmoc.bin"
echo "[ut-sapmoc] Bundled $(ls "$CLICK_DIR/lib" | grep -c '\.so') libraries."

# --- Build the click (clickable does this itself) -----------------------------
if [ "$STANDALONE" = "1" ]; then
    echo "[ut-sapmoc] Running click build ..."
    (cd build && click build click)
    echo "[ut-sapmoc] Done. Package: $(ls build/*.click)"
fi
