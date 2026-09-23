#!/bin/zsh
# 發行腳本：git tag → GitHub Release（上傳 zip）→ 更新 Homebrew tap 的 cask → brew fetch 驗證
# 用法：
#   scripts/release.sh                          # 用 dist/ 裡現成的 zip 發版（工作樹須乾淨）
#   scripts/release.sh --package                # 先跑 package.sh --no-install 並 commit 版本號，再發版
#   scripts/release.sh --package --version 1.12.0
#   scripts/release.sh --notes "說明文字"        # Release 說明；不給就用 --generate-notes
#   scripts/release.sh --dry-run                # 只印出會執行的 git / gh 指令，什麼都不動
#
# 環境變數：
#   CHORUS_TAP_REPO   Homebrew tap 的 GitHub repo（預設 gixiphy/homebrew-tap）
set -euo pipefail
cd "$(dirname "$0")/.."

PACKAGE=0
NEW_VERSION=""
NOTES=""
DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) PACKAGE=1; shift ;;
    --version) NEW_VERSION="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "未知參數：$1" >&2; exit 1 ;;
  esac
done

TAP_REPO="${CHORUS_TAP_REPO:-gixiphy/homebrew-tap}"
TAP_FILE="Casks/chorus.rb"
TAP_NAME="${TAP_REPO/\/homebrew-//}"   # gixiphy/homebrew-tap → gixiphy/tap

die() { echo "✗ $*" >&2; exit 1; }
# 會改動遠端狀態的指令都經過 run：--dry-run 時只印出來。
run() {
  if [[ $DRY -eq 1 ]]; then echo "  \$ $*"; else "$@"; fi
}

gh auth status > /dev/null 2>&1 || die "gh 尚未登入（gh auth login）"

# 工作樹要乾淨：release commit / tag 才不會夾帶其他改動（dry-run 不動任何東西，放行）。
if [[ $DRY -eq 0 && -n "$(git status --porcelain)" ]]; then
  die "工作樹有未 commit 的改動，先處理完再發版"
fi

if [[ $PACKAGE -eq 1 ]]; then
  PKG_ARGS=(--no-install)
  [[ -n "$NEW_VERSION" ]] && PKG_ARGS+=(--version "$NEW_VERSION")
  if [[ $DRY -eq 1 ]]; then
    echo "  \$ scripts/package.sh ${PKG_ARGS[*]}"
  else
    scripts/package.sh "${PKG_ARGS[@]}"
  fi
fi

VERSION=$(grep 'CFBundleShortVersionString:' project.yml | sed 's/.*"\(.*\)".*/\1/')
BUILD=$(grep 'CFBundleVersion:' project.yml | sed 's/.*"\(.*\)".*/\1/')
if [[ $DRY -eq 1 && -n "$NEW_VERSION" ]]; then VERSION="$NEW_VERSION"; fi
if [[ $DRY -eq 1 && $PACKAGE -eq 1 ]]; then BUILD=$((BUILD + 1)); fi
TAG="v$VERSION"
ZIP="dist/Chorus-$VERSION-b$BUILD.zip"
echo "▸ 發行 $VERSION (build $BUILD) → $TAG"

if [[ $PACKAGE -eq 1 ]]; then
  # package.sh 改了 project.yml 的版本號與 driver 戳記，先 commit 成 release commit。
  run git add project.yml AudioDriver/.source-version
  run git commit -q -m "chore: Release $VERSION (build $BUILD)
雜項：發行 $VERSION（build $BUILD · 打包 · 公證）"
fi

if [[ $DRY -eq 0 ]]; then
  [[ -f "$ZIP" ]] || die "找不到 $ZIP，先跑 scripts/package.sh（或加 --package）"
  # 未公證的包別台 Mac 開不了，不該發出去。stapler validate 過了才代表 ticket 真的貼上。
  xcrun stapler validate dist/Chorus.app > /dev/null 2>&1 \
    || die "dist/Chorus.app 沒有公證 ticket（package.sh 需有 notarytool 憑證才會公證）"
  git rev-parse -q --verify "refs/tags/$TAG" > /dev/null && die "tag $TAG 已存在"
  gh release view "$TAG" > /dev/null 2>&1 && die "GitHub Release $TAG 已存在"
fi

# 1. tag 並推上 GitHub（推目前分支與這個 tag）
run git tag -a "$TAG" -m "Chorus $VERSION (build $BUILD)"
run git push origin HEAD "refs/tags/$TAG"

# 2. 建 GitHub Release、上傳 zip
if [[ -n "$NOTES" ]]; then
  run gh release create "$TAG" "$ZIP" --title "Chorus $VERSION" --notes "$NOTES"
else
  run gh release create "$TAG" "$ZIP" --title "Chorus $VERSION" --generate-notes
fi

# 3. 更新 tap 的 cask：透過 GitHub Contents API 直接改檔，不需要本機 clone。
#    只動 version / sha256 兩行，其餘 stanza 由 tap 維護。
if [[ $DRY -eq 1 ]]; then
  SHA=$(printf '%064d' 0)   # 佔位，走完 sed 與檢查流程
else
  SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
fi
CUR_JSON=$(gh api "repos/$TAP_REPO/contents/$TAP_FILE") || die "讀不到 $TAP_REPO/$TAP_FILE"
FILE_SHA=$(printf '%s' "$CUR_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')
CONTENT=$(printf '%s' "$CUR_JSON" | python3 -c 'import json,sys,base64; print(base64.b64decode(json.load(sys.stdin)["content"]).decode(), end="")')
NEW_CONTENT=$(printf '%s\n' "$CONTENT" | sed -E \
  -e "s/^(  version \")[^\"]*(\")\$/\1$VERSION,$BUILD\2/" \
  -e "s/^(  sha256 \")[^\"]*(\")\$/\1$SHA\2/")
grep -q "^  version \"$VERSION,$BUILD\"\$" <<< "$NEW_CONTENT" || die "cask 裡找不到 version 行，格式變了？"
grep -q "^  sha256 \"$SHA\"\$" <<< "$NEW_CONTENT" || die "cask 裡找不到 sha256 行，格式變了？"
if [[ "$NEW_CONTENT" == "$CONTENT" ]]; then
  echo "▸ tap 已是 $VERSION,$BUILD，不用改"
else
  NEW_B64=$(printf '%s\n' "$NEW_CONTENT" | base64 | tr -d '\n')
  run gh api -X PUT "repos/$TAP_REPO/contents/$TAP_FILE" \
    -f message="chore: Bump chorus to $VERSION (build $BUILD)
雜項：chorus 升到 $VERSION（build $BUILD）" \
    -f content="$NEW_B64" -f sha="$FILE_SHA" --silent
  echo "▸ 已更新 $TAP_REPO/$TAP_FILE → $VERSION,$BUILD"
fi

[[ $DRY -eq 1 ]] && { echo "▸ dry-run 結束，未做任何改動"; exit 0; }

# 4. 驗證：拉最新 tap，brew fetch 過了代表 URL 與 sha256 都對。
brew tap "$TAP_NAME" > /dev/null 2>&1 || true
git -C "$(brew --repository "$TAP_NAME")" pull -q
brew fetch --cask "$TAP_NAME/chorus" > /dev/null || die "brew fetch 失敗：cask 的 URL 或 sha256 不對"
echo "▸ brew fetch 通過。使用者現在可以 brew install $TAP_NAME/chorus（已安裝者 brew upgrade --cask chorus）"
