#!/usr/bin/env bash
# bundle.sh — build, sign, notarize, and package LLMBar.app
#
# Three modes:
#
#   ./bundle.sh                  # dev:     ad-hoc signed (no Apple ID needed)
#   ./bundle.sh --signed         # signed:  Developer ID signed (no notarization)
#   ./bundle.sh --release        # release: signed + notarized + stapled + zipped
#                                #          + appcast.xml entry generated
#
# Required environment variables for --signed and --release:
#   DEV_ID                       # "Developer ID Application: Your Name (TEAMID)"
#
# Additionally required for --release (auto-detected from
# ~/Library/Mobile Documents/com~apple~CloudDocs/apple-dev-account/ if present):
#   APP_STORE_CONNECT_KEY_ID     # 10-char Key ID
#   APP_STORE_CONNECT_ISSUER_ID  # UUID, sourced from apple-dev-account/account.txt
#   SAKSHI_API_KEY_FILE          # path to the AuthKey_<KEYID>.p8
#   SPARKLE_PRIVATE_KEY_PATH     # path to ed25519 private key (default: ./sparkle_ed25519_priv)
#   RELEASE_DOWNLOAD_URL         # public URL where the .zip will be hosted
#
# Optional:
#   CFBundleShortVersionString   # semver, default 0.5.0
#   CFBundleVersion              # build number (integer), default 6 (> last appcast build)
#   APP_NAME                     # default "LLMBar"
#
# Outputs:
#   LLMBar.app                   # the .app bundle (always)
#   LLMBar-X.Y.Z.zip              # ditto-zipped, ready for upload (--release)
#   appcast.xml                  # updated with new release item (--release)

set -euo pipefail

cd "$(dirname "$0")"

# ─── Mode selection ─────────────────────────────────────────────────────
MODE="dev"
INSTALL=1
for arg in "$@"; do
    case "${arg}" in
        --release)    MODE="release" ;;
        --signed)     MODE="signed" ;;
        --install)    INSTALL=1 ;;
        --no-install) INSTALL=0 ;;
        "")           ;;
        *)            echo "Unknown flag: ${arg}"; exit 2 ;;
    esac
done

# ─── Config ─────────────────────────────────────────────────────────────
APP_NAME="${APP_NAME:-LLMBar}"
APP_DIR="${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
FRAMEWORKS_DIR="${CONTENTS}/Frameworks"
ENTITLEMENTS="entitlements.plist"
SHORT_VERSION="${CFBundleShortVersionString:-0.5.0}"
BUILD_VERSION="${CFBundleVersion:-6}"   # must stay above the newest appcast item (0.4.0 = build 5)
SUFEED_URL="${SUFEED_URL:-https://raw.githubusercontent.com/sriinnu/llm-bar/main/appcast.xml}"
SUPUBLIC_KEY="${SUPUBLIC_KEY:-}"  # populated below if private key is present

# ─── 1. Build the binary ────────────────────────────────────────────────
echo "==> [${MODE}] Building release binary"
swift build -c release

BINARY_PATH=".build/release/${APP_NAME}"
if [[ ! -f "${BINARY_PATH}" ]]; then
    echo "Build failed: ${BINARY_PATH} not found"
    exit 1
fi

# ─── 2. Wipe + skeleton ─────────────────────────────────────────────────
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${FRAMEWORKS_DIR}"

# ─── 3. Copy the binary + fix rpath so it finds Sparkle.framework ────────
cp "${BINARY_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

if otool -l "${MACOS_DIR}/${APP_NAME}" | grep -q "@executable_path/../Frameworks"; then
    echo "==> rpath already present"
else
    echo "==> Adding LC_RPATH @executable_path/../Frameworks"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${APP_NAME}"
fi

# ─── 3b. Copy the icon into Contents/Resources ───────────────────────────
# Apple's bundle layout requires resources under Contents/Resources, not
# Contents/MacOS — putting the raw SPM resource bundle next to the binary
# confuses codesign's automatic sealing ("code has no resources but
# signature indicates they must be present"). So copy the actual icon.svg
# straight into Resources; main.swift reads it via Bundle.main at runtime.
if [[ -f "branding/icon.svg" ]]; then
    cp "branding/icon.svg" "${RESOURCES_DIR}/icon.svg"
    echo "==> Bundled icon.svg into Contents/Resources"
fi

# Section badge glyphs (popover UI) — same reasoning as icon.svg above.
for badge in badge-lcp badge-ollama badge-hf badge-cloud; do
    if [[ -f "branding/${badge}.svg" ]]; then
        cp "branding/${badge}.svg" "${RESOURCES_DIR}/${badge}.svg"
    fi
done
echo "==> Bundled section badges into Contents/Resources"

# ─── 3c. Copy the actual app icon (Finder/Dock/Spotlight) ────────────────
# This is distinct from icon.svg above, which is only the small menu-bar
# glyph drawn at runtime. Without an .icns + CFBundleIconFile/IconName in
# Info.plist, the app has no real identity — Finder/Spotlight show the
# generic blank-document placeholder instead.
if [[ -f "branding/AppIcon.icns" ]]; then
    cp "branding/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
    echo "==> Bundled AppIcon.icns"
else
    echo "WARNING: branding/AppIcon.icns missing — app will have no Finder/Dock icon"
fi

# ─── 4. Copy Sparkle.framework if it was built ──────────────────────────
SPARKLE_XC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework"
if [[ -d "${SPARKLE_XC}" ]]; then
    SPARKLE_SLICE="${SPARKLE_XC}/macos-arm64_x86_64"
    if [[ -d "${SPARKLE_SLICE}/Sparkle.framework" ]]; then
        cp -R "${SPARKLE_SLICE}/Sparkle.framework" "${FRAMEWORKS_DIR}/"
        echo "==> Bundled Sparkle.framework"
    fi
fi

# ─── 5. Resolve public Sparkle key from private key (if available) ──────
PRIV_KEY_PATH="${SPARKLE_PRIVATE_KEY_PATH:-./sparkle_ed25519_priv}"
if [[ -z "${SUPUBLIC_KEY}" && -f "${PRIV_KEY_PATH}.pub" ]]; then
    SUPUBLIC_KEY=$(cat "${PRIV_KEY_PATH}.pub")
fi
SUPUBLIC_KEY="$(printf '%s' "${SUPUBLIC_KEY}" | tr -d '[:space:]')"

if [[ "${MODE}" == "signed" || "${MODE}" == "release" ]] && [[ -z "${SUPUBLIC_KEY}" ]]; then
    echo "ERROR: SUPUBLIC_KEY is empty in ${MODE} mode — refusing to build an"
    echo "       un-updateable app with no SUPublicEDKey in Info.plist."
    echo "       Fix: place the public key at ${PRIV_KEY_PATH}.pub."
    exit 4
fi

if [[ "${MODE}" == "signed" || "${MODE}" == "release" ]] && \
   [[ ! "${SUPUBLIC_KEY}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "ERROR: SUPUBLIC_KEY does not look like a 44-char base64 Ed25519 key:"
    echo "       '${SUPUBLIC_KEY}'"
    exit 4
fi

# ─── 6. Write Info.plist ────────────────────────────────────────────────
# Dev (ad-hoc) builds must not auto-check: an ad-hoc bundle cannot validate a
# Developer-ID-signed update, so Sparkle would pop "improperly signed" on every
# launch. "Check for Updates…" in the footer still works on demand.
SU_AUTO_CHECKS="true"; [[ "${MODE}" == "dev" ]] && SU_AUTO_CHECKS="false"
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.sriinnu.llmbar</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>LLM Bar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>SUFeedURL</key>
    <string>${SUFEED_URL}</string>
    <key>SUEnableInstallerLauncherService</key>
    <true/>
    <key>SUEnableAutomaticChecks</key>
    <${SU_AUTO_CHECKS}/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 sriinnu. All rights reserved.</string>
PLIST

if [[ -n "${SUPUBLIC_KEY}" ]]; then
    cat >> "${CONTENTS}/Info.plist" <<PLIST
    <key>SUPublicEDKey</key>
    <string>${SUPUBLIC_KEY}</string>
PLIST
fi

cat >> "${CONTENTS}/Info.plist" <<'PLIST'
</dict>
</plist>
PLIST

# ─── 7. Sign ────────────────────────────────────────────────────────────
sign_sparkle_nested() {
    local sign_id="$1"
    local extra_args="$2"
    [[ -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]] || return 0

    local sparkle_current="${FRAMEWORKS_DIR}/Sparkle.framework/Versions/Current"
    [[ -d "${sparkle_current}" ]] || sparkle_current="${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B"

    if [[ -d "${sparkle_current}/XPCServices" ]]; then
        for xpc in "${sparkle_current}/XPCServices/"*.xpc; do
            [[ -d "${xpc}" ]] || continue
            # shellcheck disable=SC2086
            codesign --force ${extra_args} --sign "${sign_id}" "${xpc}"
        done
    fi
    for helper in "${sparkle_current}/Updater.app" "${sparkle_current}/Autoupdate"; do
        [[ -e "${helper}" ]] || continue
        # shellcheck disable=SC2086
        codesign --force ${extra_args} --sign "${sign_id}" "${helper}"
    done
    # shellcheck disable=SC2086
    codesign --force ${extra_args} --sign "${sign_id}" "${FRAMEWORKS_DIR}/Sparkle.framework"
}

case "${MODE}" in
    dev)
        echo "==> Signing (ad-hoc, dev mode)"
        sign_sparkle_nested "-" ""
        codesign --force --sign - "${APP_DIR}"
        ;;
    signed|release)
        if [[ -z "${DEV_ID:-}" ]]; then
            echo "ERROR: --${MODE} requires DEV_ID env var"
            echo "       Example: DEV_ID='Developer ID Application: Your Name (TEAMID)'"
            exit 3
        fi
        echo "==> Signing with Developer ID: ${DEV_ID}"

        sign_sparkle_nested "${DEV_ID}" "--options runtime --timestamp"

        codesign --force --options runtime --timestamp \
            --entitlements "${ENTITLEMENTS}" \
            --sign "${DEV_ID}" "${APP_DIR}"

        codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
        ;;
esac

echo "==> Built ${APP_DIR} ($(du -sh "${APP_DIR}" | cut -f1))"

# ─── 8. Notarize + staple (release only) ────────────────────────────────
if [[ "${MODE}" == "release" ]]; then
    ACCOUNT_FILE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/apple-dev-account/account.txt"
    SAKSHI_KEYDIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/apple-dev-account/Sakshi"

    # Auto-detect the Sakshi API key + Issuer ID from the private
    # apple-dev-account folder if not already set via env. ISSUER_ID never
    # gets hardcoded into this tracked file — it's sourced at build time only.
    if [[ -z "${APP_STORE_CONNECT_ISSUER_ID:-}" && -f "${ACCOUNT_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${ACCOUNT_FILE}"
        APP_STORE_CONNECT_ISSUER_ID="${ISSUER_ID:-}"
    fi
    if [[ -z "${SAKSHI_API_KEY_FILE:-}" && -d "${SAKSHI_KEYDIR}" ]]; then
        SAKSHI_API_KEY_FILE=$(find "${SAKSHI_KEYDIR}" -maxdepth 1 -name "AuthKey_*.p8" | head -1)
    fi
    if [[ -z "${APP_STORE_CONNECT_KEY_ID:-}" && -n "${SAKSHI_API_KEY_FILE:-}" ]]; then
        APP_STORE_CONNECT_KEY_ID=$(basename "${SAKSHI_API_KEY_FILE}" | sed -E 's/AuthKey_(.+)\.p8/\1/')
    fi

    if [[ -z "${SAKSHI_API_KEY_FILE:-}" || -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
        echo "ERROR: --release requires notarization credentials."
        echo "       Auto-detect looks for:"
        echo "         ${SAKSHI_KEYDIR}/AuthKey_<KEYID>.p8"
        echo "         ISSUER_ID in ${ACCOUNT_FILE}"
        echo "       Or set SAKSHI_API_KEY_FILE / APP_STORE_CONNECT_KEY_ID / APP_STORE_CONNECT_ISSUER_ID directly."
        exit 4
    fi
    if [[ -z "${RELEASE_DOWNLOAD_URL:-}" ]]; then
        RELEASE_DOWNLOAD_URL="https://github.com/sriinnu/llm-bar/releases/download/v{VERSION}/${APP_NAME}-{VERSION}.zip"
    fi
    RELEASE_DOWNLOAD_URL="${RELEASE_DOWNLOAD_URL//\{VERSION\}/${SHORT_VERSION}}"
    if [[ "${RELEASE_DOWNLOAD_URL}" != *"${SHORT_VERSION}"* ]]; then
        echo "ERROR: RELEASE_DOWNLOAD_URL does not contain SHORT_VERSION=${SHORT_VERSION}"
        exit 4
    fi
    if [[ ! -f "${PRIV_KEY_PATH}" ]]; then
        echo "ERROR: --release requires a Sparkle private key at ${PRIV_KEY_PATH}"
        exit 4
    fi

    ZIP_PATH="${APP_NAME}-${SHORT_VERSION}.zip"
    echo "==> Creating notarization zip: ${ZIP_PATH}"
    rm -f "${ZIP_PATH}"
    /usr/bin/ditto --norsrc -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

    xattr -cr "${APP_DIR}" 2>/dev/null || true
    find "${APP_DIR}" -name '._*' -delete 2>/dev/null || true

    echo "==> Submitting to Apple notary service (this can take 5-30 minutes)"
    echo "==> Using key: ${SAKSHI_API_KEY_FILE} (id: ${APP_STORE_CONNECT_KEY_ID})"
    NOTARY_FAILED=0
    xcrun notarytool submit "${ZIP_PATH}" \
        --key "${SAKSHI_API_KEY_FILE}" \
        --key-id "${APP_STORE_CONNECT_KEY_ID}" \
        --issuer "${APP_STORE_CONNECT_ISSUER_ID}" \
        --wait || NOTARY_FAILED=1

    if [[ "${NOTARY_FAILED}" == "1" ]]; then
        echo "ERROR: notarytool submit failed"
        exit 5
    fi

    echo "==> Stapling notarization ticket to ${APP_DIR}"
    xcrun stapler staple "${APP_DIR}"
    xcrun stapler validate "${APP_DIR}"

    rm -f "${ZIP_PATH}"
    /usr/bin/ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"
    ZIP_SIZE=$(stat -f%z "${ZIP_PATH}")

    echo "==> Stapled & zipped: ${ZIP_PATH} (${ZIP_SIZE} bytes)"

    # ─── 9. Sign the update with Sparkle's sign_update ──────────────
    SIGN_TOOL=""
    for candidate in \
        ".build/artifacts/sparkle/Sparkle/bin/sign_update" \
        ".build/checkouts/Sparkle/bin/sign_update"; do
        if [[ -x "${candidate}" ]]; then
            SIGN_TOOL="${candidate}"
            break
        fi
    done
    if [[ -z "${SIGN_TOOL}" ]]; then
        SIGN_TOOL=$(find .build -name "sign_update" -type f -perm +111 2>/dev/null | head -1)
    fi
    if [[ -z "${SIGN_TOOL}" || ! -x "${SIGN_TOOL}" ]]; then
        echo "ERROR: Sparkle sign_update tool not found in .build/"
        exit 6
    fi

    ED_SIG=$("${SIGN_TOOL}" -f "${PRIV_KEY_PATH}" "${ZIP_PATH}")
    echo "==> Sparkle signature: ${ED_SIG}"

    PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
    export SAKSHI_APP_NAME="${APP_NAME}"
    export SAKSHI_SHORT_VERSION="${SHORT_VERSION}"
    export SAKSHI_BUILD_VERSION="${BUILD_VERSION}"
    export SAKSHI_PUB_DATE="${PUB_DATE}"
    export SAKSHI_DOWNLOAD_URL="${RELEASE_DOWNLOAD_URL}"
    export SAKSHI_ZIP_SIZE="${ZIP_SIZE}"
    export SAKSHI_ED_SIG="${ED_SIG}"

    python3 - <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")

appcast_path = "appcast.xml"
tree = ET.parse(appcast_path)
root = tree.getroot()
channel = root.find("channel")
if channel is None:
    print("ERROR: appcast.xml has no <channel> element", file=sys.stderr)
    sys.exit(1)

item = ET.Element("item")
ET.SubElement(item, "title").text = (
    f"{os.environ['SAKSHI_APP_NAME']} {os.environ['SAKSHI_SHORT_VERSION']}"
)
ET.SubElement(item, "pubDate").text = os.environ["SAKSHI_PUB_DATE"]
ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = os.environ["SAKSHI_BUILD_VERSION"]
ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = os.environ[
    "SAKSHI_SHORT_VERSION"
]
ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = "14.0"
desc = ET.SubElement(item, "description")
desc.text = "<p>See release notes on GitHub.</p>"

import re

ed_sig = os.environ["SAKSHI_ED_SIG"]
match = re.search(r'sparkle:edSignature="([^"]+)"', ed_sig)
sig_value = match.group(1) if match else ""

enclosure = ET.SubElement(item, "enclosure")
enclosure.set("url", os.environ["SAKSHI_DOWNLOAD_URL"])
enclosure.set("length", os.environ["SAKSHI_ZIP_SIZE"])
enclosure.set("type", "application/octet-stream")
enclosure.set(f"{{{SPARKLE_NS}}}edSignature", sig_value)

existing_items = list(channel.findall("item"))
insert_at = list(channel).index(existing_items[0]) if existing_items else len(list(channel))
channel.insert(insert_at, item)

ET.indent(tree, space="    ")
tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
print("==> appcast.xml updated with new <item>")
PY
fi

# ─── 10. Install to /Applications + relaunch ────────────────────────────
if [[ "${INSTALL}" == "1" ]]; then
    echo "==> Installing to /Applications"

    if pgrep -x "${APP_NAME}" > /dev/null; then
        echo "    Stopping running ${APP_NAME}"
        osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || \
            killall "${APP_NAME}" 2>/dev/null || true
        sleep 0.5
    fi

    rm -rf "/Applications/${APP_DIR}"
    cp -R "${APP_DIR}" /Applications/
    rm -rf "${APP_DIR}"

    echo "    Launching /Applications/${APP_DIR}"
    open "/Applications/${APP_DIR}"
fi

echo ""
echo "Done."
case "${MODE}" in
    dev)
        if [[ "${INSTALL}" == "1" ]]; then
            echo "Status: installed to /Applications/${APP_DIR} and launched."
        else
            echo "Status: built ./${APP_DIR} (ad-hoc signed). Pass --install to deposit to /Applications."
        fi
        ;;
    signed)
        if [[ "${INSTALL}" == "1" ]]; then
            echo "Status: signed + installed to /Applications/${APP_DIR}."
        else
            echo "Status: signed .app at ./${APP_DIR}. Pass --install to install."
        fi
        ;;
    release)
        if [[ "${INSTALL}" == "1" ]]; then
            echo "Status: notarized + stapled + installed to /Applications/${APP_DIR}. Upload ${APP_NAME}-${SHORT_VERSION}.zip + appcast.xml."
        else
            echo "Status: notarized + stapled. Upload ${APP_NAME}-${SHORT_VERSION}.zip + appcast.xml."
        fi
        ;;
esac
