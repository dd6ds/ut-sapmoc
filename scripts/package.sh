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
FRAMEWORK="${COMAPS_FRAMEWORK:-ubuntu-touch-24.04-1.x}"

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
# Trim folders you do not need, e.g. COMAPS_DATA_EXCLUDE="test_data:vulkan_shaders".
EXCLUDES="${COMAPS_DATA_EXCLUDE:-}"
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

# --- Qt plugins --------------------------------------------------------------
PLUGINS=""
for d in /usr/lib/aarch64-linux-gnu/qt6/plugins /usr/lib/qt6/plugins; do
    [ -d "$d" ] && PLUGINS="$d" && break
done
if [ -z "$PLUGINS" ]; then
    echo "[ut-sapmoc] ERROR: Qt6 plugin directory not found." >&2
    exit 1
fi
mkdir -p "$CLICK_DIR/lib/plugins"
for p in platforms platforminputcontexts imageformats iconengines \
         wayland-shell-integration wayland-graphics-integration-client \
         wayland-decoration-client position tls networkinformation; do
    [ -d "$PLUGINS/$p" ] && cp -a "$PLUGINS/$p" "$CLICK_DIR/lib/plugins/"
done
# Maliit input context (QT_IM_MODULE=maliit on Lomiri) -> on-screen keyboard.
# Built into the Docker image by scripts/build-maliit-qt6.sh.
MALIIT_PLUGIN="${MALIIT_QT6_PLUGIN:-/opt/maliit-qt6/libmaliitplatforminputcontextplugin.so}"
if [ -f "$MALIIT_PLUGIN" ]; then
    mkdir -p "$CLICK_DIR/lib/plugins/platforminputcontexts"
    install -m 644 "$MALIIT_PLUGIN" "$CLICK_DIR/lib/plugins/platforminputcontexts/"
else
    echo "[ut-sapmoc] ERROR: $MALIIT_PLUGIN missing - no on-screen keyboard." >&2
    echo "            Rebuild the Docker image (Dockerfile.noble-arm64)." >&2
    exit 1
fi

# --- Runtime libraries (Qt6 and its deps) ------------------------------------
# Bundles every shared library the binary and the plugins need, except those
# the phone must provide itself: the C runtime and everything that talks to
# the GPU and the compositor (libhybris EGL/GLES, Wayland, DRM). Copies of those
# from the container would break rendering or the session.
is_system_lib() {
    case "$(basename "$1")" in
        ld-linux*|libc.so*|libm.so*|libdl.so*|librt.so*|libpthread.so*|libresolv.so*|\
        libstdc++.so*|libgcc_s.so*|\
        libEGL*|libGL*|libGLES*|libGLX*|libGLdispatch*|libOpenGL*|libgbm*|libdrm*|\
        libwayland-*|libhybris*|libandroid*|\
        libdbus-1.so*|libsystemd.so*|libudev.so*|\
        libssl.so*|libcrypto.so*|libpulse*)
            # PulseAudio: the phone's, it must match the phone's sound server.
            # OpenSSL: the phone's. Qt's TLS backend works with any OpenSSL 3.x,
            # and the phone's own libraries (e.g. libcurl used by
            # lomiri-location-service) need the phone's newer one; a bundled
            # copy would shadow it (UT 26.04: OpenSSL 3.5).
            return 0 ;;
    esac
    return 1
}
declare -A SEEN=()
copy_libs() {
    local lib
    for lib in $(ldd "$@" 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// {print $3}' | sort -u); do
        [ -n "${SEEN[$lib]:-}" ] && continue
        SEEN[$lib]=1
        is_system_lib "$lib" && continue
        cp -Ln "$lib" "$CLICK_DIR/lib/"
        copy_libs "$lib"
    done
}
echo "[ut-sapmoc] Bundling shared libraries ..."
mapfile -t PLUGIN_SOS < <(find "$CLICK_DIR/lib/plugins" -name '*.so')
copy_libs "$CLICK_DIR/ut-sapmoc.bin" "${PLUGIN_SOS[@]}"
# Positions on Ubuntu Touch come only from lomiri-location-service. Its Qt
# plugin is built against our Qt (build-lomiri-position.sh) and added after the
# library bundling on purpose: liblomiri-location-service and dbus-cpp must be
# the phone's own (they talk to the phone's service). Geoclue does not exist
# on Ubuntu Touch, so its plugin and the polling fallback are dropped.
LOMIRI_PLUGIN="${LOMIRI_POSITION_PLUGIN:-build/lomiri-position/out/libqtposition_lomiri.so}"
if [ -f "$LOMIRI_PLUGIN" ]; then
    mkdir -p "$CLICK_DIR/lib/plugins/position"
    install -m 644 "$LOMIRI_PLUGIN" "$CLICK_DIR/lib/plugins/position/"
    rm -f "$CLICK_DIR/lib/plugins/position/libqtposition_geoclue2.so" \
          "$CLICK_DIR/lib/plugins/position/libqtposition_positionpoll.so"
else
    echo "[ut-sapmoc] WARNING: $LOMIRI_PLUGIN missing - no GPS on the phone." >&2
fi
echo "[ut-sapmoc] Bundled $(ls "$CLICK_DIR/lib" | grep -c '\.so') libraries."

# --- Build the click (clickable does this itself) -----------------------------
if [ "$STANDALONE" = "1" ]; then
    echo "[ut-sapmoc] Running click build ..."
    (cd build && click build click)
    echo "[ut-sapmoc] Done. Package: $(ls build/*.click)"
fi
