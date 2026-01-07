#!/bin/bash
set -e  # 任何命令失败立即终止脚本

# ===== 用户配置区域 =====
TARGET_DIR="/data/dcp-application"     # 需要进入的目标目录
COMPRESS_FILE=$1  # 压缩文件名
LINK_NAME="/data/dcp/deploy_t"    # 要创建的软链接路径
ENABLE_DELETE=true             # 是否删除压缩包（true/false）

# ========================
echo "正在进入目录: $TARGET_DIR"
cd "$TARGET_DIR" || { echo "[错误] 无法进入目录：$TARGET_DIR"; exit 1; }

# 解压并获取顶级目录名（核心改进点）
echo "正在解压: $COMPRESS_FILE"
TOP_DIR=$(tar -tzf "$COMPRESS_FILE" | head -1 | cut -f1 -d"/")
if [ -z "$TOP_DIR" ]; then
  echo "[错误] 压缩包内没有顶级目录"
  exit 2
fi

# 强制删除可能存在的旧目录（安全操作）
if [ -d "$TOP_DIR" ]; then
  echo "检测到已存在目录 $TOP_DIR，执行清理..."
  rm -rf "$TOP_DIR"
fi

# 执行解压
tar -xzf "$COMPRESS_FILE"
UNPACKED_DIR="$TOP_DIR"

# 验证解压结果
if [ ! -d "$UNPACKED_DIR" ]; then
  echo "[错误] 解压目录验证失败：$UNPACKED_DIR"
  echo "当前目录内容："
  ls -l
  exit 3
fi

# 创建软链接
echo "创建软链接: $LINK_NAME → $UNPACKED_DIR"
ln -sfn "$(realpath "$UNPACKED_DIR")" "$LINK_NAME"

if $ENABLE_DELETE; then
  echo "正在安全清理压缩包..."
  if [ -f "$COMPRESS_FILE" ]; then
    rm -v -- "$COMPRESS_FILE"  # -v 显示删除详情，-- 防止特殊文件名错误
    echo "[成功] 压缩包已删除"
  else
    echo "[警告] 压缩包不存在：$COMPRESS_FILE"
  fi
fi
echo "操作成功完成！"
echo "操作成功！链接指向：$(ls -l $LINK_NAME)"
