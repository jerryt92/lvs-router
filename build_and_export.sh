#!/bin/bash
set -e

echo "=========================================="
echo "    LVS 离线镜像本地构建与压缩打包脚本    "
echo "=========================================="

# 1. 强制采用跨平台构建模式 (保证打出来的是 linux/amd64 给目标物理机/虚拟机用)
echo "[1/3] 开始构建 lvs-router 镜像..."
docker build --platform=linux/amd64 -f docker/Dockerfile -t lvs-router:latest .

# 2. 从本地缓存或远端拉取测试客户端要用的官方镜像
echo "[2/3] 拉取或确认存有客户端 curl 的依赖镜像..."
docker pull --platform=linux/amd64 curlimages/curl:8.8.0

# 3. 将所有涉及到的镜像一并打包导出成一个 tar 文件在当前目录中
echo "[3/3] 正在汇总打包（导出文件为: lvs-offline-images.tar）..."
docker save -o lvs-offline-images.tar lvs-router:latest curlimages/curl:8.8.0

echo "=========================================="
echo "成功! 打包文件保存至当前目录 -> lvs-offline-images.tar"
echo "你可以将此文件连同项目文件一同上传到断网机器上进行 docker load"
