# 02rapi 개발 환경 노트

다른 맥에서 이 프로젝트를 이어서 작업하거나 릴리스할 때 필요한 것들.

## 1. 설치해야 하는 것

| 항목 | 왜 필요한가 | 설치 / 확인 |
|---|---|---|
| **Xcode 27 이상** (macOS 26 SDK) | `glassEffect`, `MeshGradient`, SwiftUI 셰이더 사용 | App Store. `xcodebuild -version` |
| **Metal Toolchain** (Xcode 구성요소) | 소리원 렌즈 셰이더 `BlobLens.metal` 컴파일. 없으면 빌드가 `missing Metal Toolchain` 으로 실패 | `xcodebuild -downloadComponent MetalToolchain` (약 840MB). 확인: `xcodebuild -showComponent MetalToolchain` → `Status: installed` |
| **IINA** (`/Applications/IINA.app`) | 라디오 재생 엔진 libmpv 를 IINA 안의 dylib 로 씀. `bundle.sh` 가 여기서 복사해 앱에 넣고, 개발 중 실행도 번들에 없으면 IINA 것을 씀 | https://iina.io |
| **Apple Development 서명 인증서** | `bundle.sh` 가 dylib·앱을 `Apple Development` 로 재서명 (없으면 ad-hoc 으로 대체되어 로컬 실행은 됨) | Xcode → Settings → Accounts. 확인: `security find-identity -v -p codesigning` |
| **GitHub CLI `gh`** (로그인 상태) | 릴리스 생성·dmg 첨부 | `brew install gh` → `gh auth login` |
| **Python 3** | (선택) `tools/sounds/` 로 효과음 다시 만들 때만. 표준 라이브러리만 씀 | macOS 기본 또는 `brew install python` |

DMG 배경 이미지 `~/Downloads/02rapiWallp.png` 도 필요하다 (`makedmg.sh`). 리포에 없으므로
다른 맥에서는 이전 릴리스 dmg 안의 `.background/background.png` 를 꺼내 그 경로에 두면 된다.

```bash
gh release download -R marzipan2025/02rapi -p 02rapi.dmg -D /tmp/02rapi-bg
hdiutil attach /tmp/02rapi-bg/02rapi.dmg -nobrowse -readonly -mountpoint /tmp/02rapi-bg/mnt
cp /tmp/02rapi-bg/mnt/.background/background.png ~/Downloads/02rapiWallp.png
hdiutil detach /tmp/02rapi-bg/mnt
```

## 2. 릴리스 절차

버전은 `02rapi/02rapi.xcodeproj/project.pbxproj` 의 `MARKETING_VERSION` (Debug/Release 두 곳)이 유일한 기준.
앱 내 업데이터는 GitHub 의 latest 릴리스 태그(`vX.Y.Z`)를 현재 버전과 비교하고, 첨부된 `.dmg` 를 받아 설치한다.
**릴리스에는 반드시 dmg 를 첨부할 것.**

1. `MARKETING_VERSION` 올리고 main 에 커밋·푸시.
2. Release 아카이브 후 앱을 `~/Downloads/02rapi YYYY-MM-DD HH-MM-SS/` 에 복사
   (`bundle.sh`·`makedmg.sh` 가 가장 최근 `~/Downloads/02rapi *` 폴더를 찾는다).
   ```bash
   cd 02rapi
   xcodebuild -project 02rapi.xcodeproj -scheme 02rapi -configuration Release -archivePath /tmp/02rapi.xcarchive archive
   D="$HOME/Downloads/02rapi $(date '+%Y-%m-%d %H-%M-%S')"; mkdir -p "$D"
   ditto /tmp/02rapi.xcarchive/Products/Applications/02rapi.app "$D/02rapi.app"
   ```
3. `./bundle.sh` (libmpv 번들 + 재서명) → `./makedmg.sh` (→ `02rapi/02rapi.dmg`, gitignore 됨).
   마운트 직후 Finder 가 디스크를 못 찾는 오류(-1728)는 스크립트가 기다렸다가 3번까지 다시 시도한다.
   그래도 실패하면 `hdiutil info` 로 남은 `02rapi` 이미지를 확인해
   `hdiutil detach /dev/diskN -force` 로 분리한 뒤 다시 실행.
4. 태그·릴리스:
   ```bash
   git tag vX.Y.Z && git push origin vX.Y.Z
   gh release create vX.Y.Z 02rapi/02rapi.dmg --title vX.Y.Z --notes "..."
   ```

## 3. 업데이트 기능 테스트

Debug 빌드는 Xcode 에서 실행한 앱을 덮어쓰지 않도록 업데이트 확인을 하지 않는다. 환경변수로 켠다.

- `RAPI_UPDATE_CURRENT_VERSION=1.0.0` — 현재 버전을 이 값으로 간주 → Update 버튼이 나온다.
- `RAPI_UPDATE_AUTOINSTALL=1` — (Debug 전용) 드래그 없이 바로 설치 시작.
- 업데이트 직후 연출(Updated)만 보기: `defaults write com.artbrain.02rapi updatedToVersion <현재 버전>` 후 실행.

Xcode 스킴(Run → Environment Variables)에 넣어 쓰되, 스킴 변경은 커밋하지 않는다.
설치까지 시험할 때는 /Applications 가 아닌 임시 폴더의 사본으로 할 것 (그 사본이 교체된다).

## 4. 효과음

`update_hum.wav`(설치 중 허밍 루프), `update_pop.wav` / `updated_pop.wav`(Update·Updated 등장음)는
`tools/sounds/` 의 스크립트로 직접 합성한 것이다. 다시 만들 때:

```bash
python3 tools/sounds/update_hum.py 02rapi/02rapi
python3 tools/sounds/update_pops.py 02rapi/02rapi
```

`ui_pop.mp3` 는 Pixabay "UI Pop Sound" (Pixabay Content License).
