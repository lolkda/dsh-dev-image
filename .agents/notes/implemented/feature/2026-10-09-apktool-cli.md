# Agent Note: 镜像内全局 apktool CLI

Status: implemented

## Problem

镜像已有 Java 与 adb，但缺少可从任意工作目录调用的 apktool。

## Decision

固定官方 Apktool 3.0.3 JAR 与发布资产 SHA-256，安装在 /opt/apktool；在已有 PATH 的 /usr/local/bin 安装可执行脚本，以绝对路径调用镜像 Java 和 JAR，并原样传递参数，不改变工作目录。不改入口或用户 PATH。

## Alternatives considered

Debian apt 包安装最简洁且自动管理依赖，但会引入发行版 Java 依赖，违背镜像单一 Java 工具链约束，因此采用官方 JAR。仅提供 java -jar 命令无需包装，但不满足直接调用 apktool 的需求。

## Testing

配置测试验证固定下载和校验；替身 Java 测试验证脚本参数、退出码与工作目录保留。构建期及镜像冒烟包含从 /tmp 执行的登录和非登录 shell 检查，并包含裸 docker exec 检查。

本地 Node 回归 126 项通过、1 项非 root 测试跳过；官方 JAR 实际下载的 SHA-256 匹配，使用现有 /opt/java/bin/java 从 /tmp 执行 --version 返回 3.0.3。当前环境无 Docker CLI，完整镜像构建与容器冒烟尚未在本地执行。

## Consequences

用户无需定位 JAR 或设置 PATH，即可直接调用 apktool；复用单一 Java 工具链。下载依赖 GitHub 可用性，升级需同步版本与哈希。CLI 版本冒烟不代表所有 APK 都能解包或重建。

## Related notes audit

检索现有笔记的 apktool、PATH、Java、java、adb：root-only-runtime 仅涉及身份与既有 PATH 不变量，属于相关但不重叠决策；无可复用的 apktool 安装笔记。
