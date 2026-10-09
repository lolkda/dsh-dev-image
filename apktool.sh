#!/bin/sh
# 固定使用镜像工具链；不改变 cwd，保留相对 APK 路径和参数边界。
exec /opt/java/bin/java -jar /opt/apktool/apktool.jar "$@"
