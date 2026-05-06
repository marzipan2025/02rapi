#!/bin/bash
#
# bundle.sh
# Xcode Archive > Distribute App > Custom > Copy App 으로 생성된
# ~/Downloads/02rapi YYYY-MM-DD HH-MM-SS/02rapi.app 에 libmpv 및
# 관련 dylib를 번들링하고 재서명한다.
#
set -e

APP_NAME="02rapi"
IINA_FW="/Applications/IINA.app/Contents/Frameworks"
SIGN_IDENTITY="Apple Development"

# 1. Downloads 안의 가장 최근 아카이브 폴더 찾기
ARCHIVE_DIR=$(ls -td "$HOME/Downloads/${APP_NAME} "* 2>/dev/null | head -1)
if [ -z "$ARCHIVE_DIR" ]; then
    echo "Error: '${APP_NAME} ...' 폴더를 Downloads에서 찾을 수 없습니다."
    echo "Xcode에서 Product > Archive > Distribute App > Custom > Copy App 을 먼저 실행하세요."
    exit 1
fi

APP="$ARCHIVE_DIR/${APP_NAME}.app"
if [ ! -d "$APP" ]; then
    echo "Error: $APP 가 존재하지 않습니다."
    exit 1
fi

echo "Target: $APP"

# 2. libmpv의 의존성 클로저 계산 (BFS로 @rpath 참조 재귀 추적)
DEST_FW="$APP/Contents/Frameworks"
mkdir -p "$DEST_FW"

if [ ! -d "$IINA_FW" ]; then
    echo "Error: IINA가 설치되어 있지 않습니다 ($IINA_FW)"
    exit 1
fi

ARCH=$(uname -m)  # arm64 or x86_64

QUEUE=("libmpv.2.dylib")
RESOLVED=()
SEEN=" "

while [ ${#QUEUE[@]} -gt 0 ]; do
    current="${QUEUE[0]}"
    QUEUE=("${QUEUE[@]:1}")

    # 중복 방지 (bash 3.2 호환: 공백 구분 문자열로 집합 구현)
    case "$SEEN" in
        *" $current "*) continue ;;
    esac
    SEEN="$SEEN$current "

    # IINA 폴더에 없으면 스킵 (시스템 라이브러리거나 옵션 의존성)
    [ ! -f "$IINA_FW/$current" ] && continue

    RESOLVED+=("$current")

    # 이 dylib가 참조하는 @rpath 의존성을 큐에 추가
    while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        QUEUE+=("$dep")
    done < <(otool -arch "$ARCH" -L "$IINA_FW/$current" 2>/dev/null \
             | awk '$1 ~ /^@rpath\// {print $1}' \
             | sed 's|^@rpath/||' \
             | grep -v "^${current}$" || true)
done

echo "의존성 클로저: ${#RESOLVED[@]} 개 dylib"

# 3. 클로저에 포함된 dylib만 복사
echo "dylib 복사 중..."
for name in "${RESOLVED[@]}"; do
    cp -f "$IINA_FW/$name" "$DEST_FW/$name"
done
echo "  → ${#RESOLVED[@]} 개 복사 완료"

# 3. 각 dylib 재서명 (bottom-up 원칙)
echo "dylib 재서명 중..."
for dylib in "$DEST_FW"/*.dylib; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$dylib" >/dev/null 2>&1 || {
        echo "  warning: $(basename "$dylib") 재서명 실패, ad-hoc으로 재시도"
        codesign --force --sign - --timestamp=none "$dylib" >/dev/null 2>&1
    }
done
echo "  → 완료"

# 4. 앱 번들 재서명 (Frameworks 하위는 이미 서명됐으므로 --deep 불필요)
echo "앱 재서명 중..."
codesign --force --sign "$SIGN_IDENTITY" \
    --timestamp=none \
    --preserve-metadata=entitlements,identifier,flags \
    "$APP" >/dev/null 2>&1 || {
    echo "  warning: Apple Development 서명 실패, ad-hoc으로 재시도"
    codesign --force --sign - \
        --preserve-metadata=entitlements,identifier,flags \
        "$APP" >/dev/null 2>&1
}

# 5. 서명 검증
if codesign --verify --verbose=1 "$APP" >/dev/null 2>&1; then
    echo "  → 검증 통과"
else
    echo "  warning: 서명 검증 실패 — ad-hoc 상태일 수 있음 (로컬 실행은 가능)"
fi

echo ""
echo "Build Succeed"
echo "App: $APP"
