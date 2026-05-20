#!/bin/bash

# Claude API 额度显示 - 编译和运行脚本

echo "🚀 开始构建并安装 CodexQuota 项目..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 进入项目目录
cd "$(dirname "$0")" || exit 1

# 检查 Swift 是否安装
if ! command -v swift &> /dev/null; then
    echo "❌ 错误: Swift 未找到"
    echo "请确保已安装 Swift 工具链"
    exit 1
fi

echo "✅ Swift 版本: $(swift --version)"
echo ""

# 清除旧的构建（可选，取消下面的注释来清除）
# echo "清除旧的构建文件..."
# rm -rf .build

RESOLVED_CODESIGN_IDENTITY="$(./scripts/resolve-codesign-identity.sh)"
echo "✅ 使用签名身份: $RESOLVED_CODESIGN_IDENTITY"

echo ""
echo "📦 构建并安装中..."
"$(dirname "$0")/scripts/install-app.sh" debug

if [ $? -ne 0 ]; then
    echo ""
    echo "❌ 安装失败!"
    exit 1
fi

echo ""
echo "✅ 安装成功!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🎉 已从 /Applications 启动应用"
