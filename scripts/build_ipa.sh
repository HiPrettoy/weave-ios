# macOS 本地构建脚本（有 Mac + Xcode 时用）
# 用法：./scripts/build_ipa.sh
# 版本号不从这里传：唯一真源是 project.yml 的 MARKETING_VERSION，
# 产物版本与它不一致时脚本直接失败（与 CI 的 Resolve & verify version 一致）。

set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "需要 xcodegen：brew install xcodegen"
  exit 1
fi

DECLARED=$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' project.yml)
if [ -z "$DECLARED" ]; then
  echo "project.yml 里找不到 MARKETING_VERSION"
  exit 1
fi
echo "==> 目标版本（project.yml）：$DECLARED"

echo "==> 生成工程"
xcodegen generate

echo "==> 归档（未签名）"
rm -rf build
xcodebuild archive \
  -project Weave.xcodeproj \
  -scheme Weave \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath build/Weave.xcarchive \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  EXPANDED_CODE_SIGN_IDENTITY="" \
  ONLY_ACTIVE_ARCH=NO

APP_PATH="build/Weave.xcarchive/Products/Applications/Weave.app"
if [ ! -d "$APP_PATH" ]; then
  echo "归档产物不存在：$APP_PATH"
  exit 1
fi

BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Info.plist")
if [ "$BUILT" != "$DECLARED" ]; then
  echo "产物版本 ($BUILT) 与 project.yml 的 MARKETING_VERSION ($DECLARED) 不一致"
  exit 1
fi
VERSION="$BUILT"
echo "==> 版本校验通过：$VERSION"

echo "==> 打包 Payload"
mkdir -p build/Payload
cp -R "$APP_PATH" build/Payload/
rm -rf build/Payload/Weave.app/_CodeSignature || true

cd build
# -X 不写扩展属性，避免部分侧载工具解压出错
zip -qrX "Weave-v${VERSION}.ipa" Payload
echo "==> 完成：$(pwd)/Weave-v${VERSION}.ipa"
