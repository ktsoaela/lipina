#!/usr/bin/env bash
# Build the Android APK (works on Android and Huawei phones) inside Docker: no local
# Flutter, Java or Android SDK needed. iOS can't be built in Docker; see README.
#
#   cd mobile && bash docker-build.sh                          # → mobile/dist/lipina.apk
#   LIPINA_API=https://music.example.com bash docker-build.sh  # default server shown at login
set -euo pipefail
cd "$(dirname "$0")"
IMAGE="${FLUTTER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
API="${LIPINA_API:-http://10.0.2.2:8000}"
mkdir -p dist

# MSYS_NO_PATHCONV stops Git Bash on Windows from rewriting the container paths.
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$(pwd -W 2>/dev/null || pwd):/src:ro" \
  -v "$(pwd -W 2>/dev/null || pwd)/dist:/out" \
  -v lipina-pub-cache:/root/.pub-cache \
  -v lipina-gradle:/root/.gradle \
  -e LIPINA_API="$API" \
  "$IMAGE" bash -euo pipefail -c '
    rm -rf /app && mkdir /app
    tar -C /src --exclude=./build --exclude=./dist --exclude=./.dart_tool -cf - . | tar -C /app -xf -
    cd /app
    flutter config --no-analytics >/dev/null
    flutter create --org za.lipina --project-name lipina --platforms android,ios . >/dev/null
    flutter pub get
    flutter analyze --no-fatal-infos --no-fatal-warnings
    flutter test
    flutter build apk --release --dart-define=LIPINA_API="$LIPINA_API"
    cp build/app/outputs/flutter-apk/app-release.apk /out/lipina.apk
  '
echo "APK: $(pwd)/dist/lipina.apk"
