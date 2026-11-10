#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_PROJECT="$PROJECT_ROOT/android"
BUILD_ROOT="$PROJECT_ROOT/.local/android"
ACTION="${1:-verify}"
if [[ -z "${JAVA_HOME:-}" ]] || ! "$JAVA_HOME/bin/java" -version 2>&1 | head -1 | grep -q '"17\.'; then
    export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
fi
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
mkdir -p "$BUILD_ROOT"
case "$ACTION" in
    verify)
        "$ANDROID_PROJECT/gradlew" -p "$ANDROID_PROJECT" :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
        ;;
    debug)
        "$ANDROID_PROJECT/gradlew" -p "$ANDROID_PROJECT" :app:assembleDebug
        cp "$ANDROID_PROJECT/app/build/outputs/apk/debug/app-debug.apk" "$BUILD_ROOT/Yearly-debug.apk"
        ;;
    release)
        if [[ ! -f "$BUILD_ROOT/signing.properties" ]]; then
            umask 077
            export YEARLY_ANDROID_STORE_PASSWORD="$(openssl rand -hex 24)"
            "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$BUILD_ROOT/yearly-personal.p12" \
                -storetype PKCS12 -storepass:env YEARLY_ANDROID_STORE_PASSWORD \
                -keypass:env YEARLY_ANDROID_STORE_PASSWORD -alias yearly \
                -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=Yearly Personal'
            cat > "$BUILD_ROOT/signing.properties" <<PROPERTIES
storeFile=$BUILD_ROOT/yearly-personal.p12
storePassword=$YEARLY_ANDROID_STORE_PASSWORD
keyAlias=yearly
keyPassword=$YEARLY_ANDROID_STORE_PASSWORD
PROPERTIES
            unset YEARLY_ANDROID_STORE_PASSWORD
        fi
        "$ANDROID_PROJECT/gradlew" -p "$ANDROID_PROJECT" :app:assembleRelease
        cp "$ANDROID_PROJECT/app/build/outputs/apk/release/app-release.apk" "$BUILD_ROOT/Yearly-android.apk"
        "$ANDROID_HOME/build-tools/34.0.0/apksigner" verify --print-certs "$BUILD_ROOT/Yearly-android.apk"
        ;;
    install)
        : "${YEARLY_ANDROID_DEVICE:?Set the authorized adb device serial}"
        "$ANDROID_HOME/platform-tools/adb" -s "$YEARLY_ANDROID_DEVICE" install -r "$BUILD_ROOT/Yearly-android.apk"
        ;;
    *) echo 'Usage: ./scripts/android.sh verify | debug | release | install' >&2; exit 2 ;;
esac
