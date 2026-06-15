#!/bin/bash
# BiliMerge APK 构建脚本

BUILD_TYPE="${1:-debug}"
TIMESTAMP=$(date +%Y%m%d-%H%M)

echo "================================"
echo " BiliMerge APK 构建"
echo " 类型: $BUILD_TYPE"
echo " 时间: $TIMESTAMP"
echo "================================"
echo ""

/c/flutter/bin/flutter build apk --"$BUILD_TYPE"
RC=$?

if [ $RC -ne 0 ]; then
    echo ""
    echo "❌ 构建失败"
    exit $RC
fi

OUTPUT_DIR="build/app/outputs/flutter-apk"
SOURCE_APK="$OUTPUT_DIR/app-$BUILD_TYPE.apk"
TARGET_APK="$OUTPUT_DIR/bilimerge-$BUILD_TYPE-$TIMESTAMP.apk"

if [ -f "$SOURCE_APK" ]; then
    cp "$SOURCE_APK" "$TARGET_APK"
    echo ""
    echo "✅ 构建完成！"
    echo "   $TARGET_APK"
fi
