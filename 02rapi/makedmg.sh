#!/bin/bash
#
# makedmg.sh
# bundle.sh 실행 후, ~/Downloads/02rapi ... 의 번들된 앱을 사용해
# /Users/byeongsu.kim/claude_04/LiquidGlassApp/02rapi.dmg 를 생성한다.
# 창 레이아웃은 claude_kanji/dmg/create_dmg.sh 와 동일.
#
set -e

APP_NAME="02rapi"
VOL_NAME="02rapi"
DMG_NAME="02rapi.dmg"
BG_IMG="$HOME/Downloads/02rapiWallp.png"

# 스크립트가 있는 폴더 = 출력 폴더
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$SCRIPT_DIR/$DMG_NAME"

# 1. 번들된 앱 찾기
ARCHIVE_DIR=$(ls -td "$HOME/Downloads/${APP_NAME} "* 2>/dev/null | head -1)
if [ -z "$ARCHIVE_DIR" ]; then
    echo "Error: '${APP_NAME} ...' 폴더를 Downloads에서 찾을 수 없습니다."
    exit 1
fi

APP_PATH="$ARCHIVE_DIR/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH 가 없습니다."
    exit 1
fi

if [ ! -d "$APP_PATH/Contents/Frameworks" ] || [ -z "$(ls -A "$APP_PATH/Contents/Frameworks" 2>/dev/null)" ]; then
    echo "Error: $APP_PATH 에 Frameworks가 비어 있습니다. 먼저 ./bundle.sh 실행 필요."
    exit 1
fi

if [ ! -f "$BG_IMG" ]; then
    echo "Error: 배경 이미지가 없습니다: $BG_IMG"
    exit 1
fi

echo "App:        $APP_PATH"
echo "Background: $BG_IMG"
echo "Output:     $OUTPUT"

# 2. 스테이징 디렉터리 준비
TEMP_DIR=$(mktemp -d)
DMG_TEMP="$TEMP_DIR/dmg_temp"
mkdir -p "$DMG_TEMP"

cp -R "$APP_PATH" "$DMG_TEMP/${APP_NAME}.app"
ln -s /Applications "$DMG_TEMP/Applications"
mkdir -p "$DMG_TEMP/.background"
cp "$BG_IMG" "$DMG_TEMP/.background/background.png"

# 3. 이전 실행에서 남은 마운트가 있으면 먼저 강제 언마운트
if [ -d "/Volumes/$VOL_NAME" ]; then
    echo "이전 마운트 발견: /Volumes/$VOL_NAME — 강제 언마운트"
    hdiutil detach "/Volumes/$VOL_NAME" -force >/dev/null 2>&1 || \
        diskutil unmount force "/Volumes/$VOL_NAME" >/dev/null 2>&1 || true
fi

# 4. HFS+ RW 이미지 생성 (APFS에서는 창 속성 설정이 불안정함)
rm -f "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"

hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$DMG_TEMP" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$TEMP_DIR/temp.dmg" >/dev/null

# 5. 마운트 후 Finder로 창 꾸미기
MOUNT_DIR=$(hdiutil attach "$TEMP_DIR/temp.dmg" | grep "/Volumes/" | awk '{print $3}')
echo "Mounted: $MOUNT_DIR"

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 740, 580}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {195, 240}
        set position of item "Applications" of container window to {445, 240}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# 6. 언마운트 — Finder가 핸들 놓을 때까지 재시도, 끝내 강제 언마운트
sync
sleep 2

detach_ok=0
for attempt in 1 2 3; do
    if hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1; then
        detach_ok=1
        break
    fi
    sleep 1
done

if [ $detach_ok -eq 0 ]; then
    echo "일반 detach 실패 — 강제 detach 시도"
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || \
        diskutil unmount force "$MOUNT_DIR" >/dev/null 2>&1 || {
            echo "Error: $MOUNT_DIR 언마운트 실패"
            exit 1
        }
fi

# 7. 볼륨이 완전히 사라질 때까지 잠깐 대기 (컨버트 소스 락 해제)
for i in 1 2 3 4 5; do
    [ ! -d "$MOUNT_DIR" ] && break
    sleep 1
done

# 8. 압축 읽기전용 DMG로 변환
hdiutil convert "$TEMP_DIR/temp.dmg" -format UDZO -o "$OUTPUT" >/dev/null

rm -rf "$TEMP_DIR"

echo ""
echo "DMG created: $OUTPUT"
echo "Size: $(du -h "$OUTPUT" | awk '{print $1}')"
