# macOS 本地构建脚本（有 Mac + Xcode 时用）
# 用法：./scripts/build_ipa.sh [版本号]

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "需要 xcodegen：brew install xcodegen"
  exit 1
fi

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
  ONLY_ACTIVE_ARCH=NO

echo "==> 打包 Payload"
mkdir -p build/Payload
cp -R build/Weave.xcarchive/Products/Applications/Weave.app build/Payload/
rm -rf build/Payload/Weave.app/_CodeSignature || true

cd build
zip -qry "Weave-v${VERSION}.ipa" Payload
echo "==> 完成：$(pwd)/Weave-v${VERSION}.ipa"
