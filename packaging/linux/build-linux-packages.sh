#!/usr/bin/env bash
#
# 把 Simple Live 官方发布的 Linux .deb 转换成 RPM 与 AppImage。
#
#   ./build-linux-packages.sh --deb simple_live_app-1.13.2+11302-linux.deb --outdir dist
#
# 可选参数：
#   --version  1.13.2    RPM 版本（默认从 deb 的 control 文件推导）
#   --release  1         RPM 发行号，修 bug 重发时递增
#   --outdir   dist      产物目录
#   --skip-rpm           只做 AppImage
#   --skip-appimage      只做 RPM
#
# 依赖：ar、tar、zstd/xz、rpmbuild（Fedora: dnf install rpm-build，Debian/Ubuntu: apt install rpm）
#      appimagetool 缺失时会自动下载到 .cache/ 目录。
#
# 说明：不重新编译任何代码，二进制与官方 deb 完全一致，仅重新组织文件布局并补充元数据。

set -euo pipefail
umask 022   # rpmbuild 的 %install 也受此影响，必须显式设定，否则文件会被打成 0600

NAME="simple-live"
VERSION=""
RELEASE="1"
OUTDIR="dist"
DEB=""
DO_RPM=1
DO_APPIMAGE=1
ARCH="x86_64"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/simple-live-packaging"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --deb)          DEB="$2"; shift 2 ;;
        --version)      VERSION="$2"; shift 2 ;;
        --release)      RELEASE="$2"; shift 2 ;;
        --outdir)       OUTDIR="$2"; shift 2 ;;
        --skip-rpm)     DO_RPM=0; shift ;;
        --skip-appimage) DO_APPIMAGE=0; shift ;;
        -h|--help)      usage ;;
        *)              die "未知参数：$1（--help 查看用法）" ;;
    esac
done

[ -n "$DEB" ] || die "必须用 --deb 指定 .deb 文件"
[ -f "$DEB" ] || die "找不到文件：$DEB"
DEB="$(cd "$(dirname "$DEB")" && pwd)/$(basename "$DEB")"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

for cmd in ar tar; do command -v "$cmd" >/dev/null || die "缺少命令：$cmd"; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/simple-live-pack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- 解包 deb
log "解包 $(basename "$DEB")"
mkdir -p "$WORK/deb"
( cd "$WORK/deb" && ar x "$DEB" )

DATA=""
for f in "$WORK"/deb/data.tar.*; do [ -e "$f" ] && DATA="$f"; done
[ -n "$DATA" ] || die "deb 内没有 data.tar.*"

mkdir -p "$WORK/root"
STREAM="$WORK/data.tar"
case "$DATA" in
    *.zst) command -v zstd >/dev/null || die "缺少 zstd（dnf install zstd / apt install zstd）"
           zstd -dc "$DATA" > "$STREAM" ;;
    *.xz)  command -v xz   >/dev/null || die "缺少 xz"
           xz -dc "$DATA" > "$STREAM" ;;
    *.gz)  gzip -dc "$DATA" > "$STREAM" ;;
    *)     cp "$DATA" "$STREAM" ;;
esac
# -m：不还原 mtime，避免在受限文件系统上因 utime 失败而中断
tar -xmf "$STREAM" -C "$WORK/root"

APP="$(find "$WORK/root" -maxdepth 3 -name 'simple_live_app' -type f -print -quit)"
[ -n "$APP" ] || die "deb 内找不到 simple_live_app 可执行文件"
APPDIR_SRC="$(dirname "$APP")"

CTRL="$(mktemp "$WORK/control.XXXX")"
for f in "$WORK"/deb/control.tar.*; do
    [ -e "$f" ] || continue
    case "$f" in
        *.zst) zstd -dc "$f" | tar -xO ./control > "$CTRL" 2>/dev/null || true ;;
        *.xz)  tar -xJO -f "$f" ./control > "$CTRL" 2>/dev/null || true ;;
        *.gz)  tar -xzO -f "$f" ./control > "$CTRL" 2>/dev/null || true ;;
    esac
done

if [ -z "$VERSION" ]; then
    VERSION="$(awk -F': ' '/^Version:/{print $2}' "$CTRL" | cut -d+ -f1)"
    [ -n "$VERSION" ] || die "无法从 deb 推导版本号，请用 --version 指定"
    log "从 deb 推导版本号：$VERSION"
fi

# RPM 的 Version 字段不允许 '-'，去掉任何预发布后缀分隔符
RPMVER="${VERSION//-/_}"

# ---------------------------------------------------------- 组装公共文件树
STAGE="$WORK/stage/$NAME-$RPMVER"
mkdir -p "$STAGE/applications" "$STAGE/icons/128x128" "$STAGE/icons/256x256"
cp -R "$APPDIR_SRC" "$STAGE/opt_tmp"
mkdir -p "$STAGE/opt"
mv "$STAGE/opt_tmp" "$STAGE/opt/$(basename "$APPDIR_SRC")"

ICON128="$(find "$WORK/root" -path '*icons*128*' -name 'simple_live_app.png' -print -quit)"
ICON256="$(find "$WORK/root" -path '*icons*256*' -name 'simple_live_app.png' -print -quit)"
[ -n "$ICON256" ] || ICON256="$ICON128"
[ -n "$ICON128" ] || die "deb 内找不到图标"
cp "$ICON128" "$STAGE/icons/128x128/simple_live_app.png"
cp "$ICON256" "$STAGE/icons/256x256/simple_live_app.png"

cp "$HERE/rpm/simple_live_app.desktop" "$STAGE/applications/"
cp "$HERE/rpm/simple_live_app.metainfo.xml" "$STAGE/" 2>/dev/null || true
cp "$(dirname "$HERE")/../LICENSE" "$STAGE/LICENSE" 2>/dev/null || echo "GPL-3.0-or-later" > "$STAGE/LICENSE"

# 权限兜底：deb 解出来的位可能不全，普通用户必须可读、可执行
chmod -R u=rwX,go=rX "$STAGE"
chmod 0755 "$STAGE/opt/$(basename "$APPDIR_SRC")/simple_live_app"

# ------------------------------------------------------------------- RPM
if [ "$DO_RPM" = 1 ]; then
    command -v rpmbuild >/dev/null || die "缺少 rpmbuild：Fedora 用 dnf install rpm-build，Debian/Ubuntu 用 apt install rpm"

    log "构建 RPM $NAME-$RPMVER-$RELEASE"
    tar -czf "$WORK/$NAME-$RPMVER-linux-$ARCH.tar.gz" -C "$STAGE" .
    sed -e "s|@VERSION@|$RPMVER|g" \
        -e "s|@RELEASE@|$RELEASE|g" \
        -e "s|@ARCH@|$ARCH|g" \
        -e "s|@DATE@|$(LC_ALL=C date '+%a %b %d %Y')|g" \
        "$HERE/rpm/simple-live.spec.in" > "$WORK/simple-live.spec"

    mkdir -p "$WORK/rpmbuild"
    rpmbuild -bb --noclean \
        --define "_topdir $WORK/rpmbuild" \
        --define "_sourcedir $WORK" \
        "$WORK/simple-live.spec" > "$WORK/rpmbuild.log" 2>&1 \
        || { tail -25 "$WORK/rpmbuild.log" >&2; die "rpmbuild 失败（完整日志已输出在上方）"; }

    RPM="$(find "$WORK/rpmbuild/RPMS" -name '*.rpm' -print -quit)"
    cp "$RPM" "$OUTDIR/"
    log "RPM  ->  $OUTDIR/$(basename "$RPM")"
fi

# --------------------------------------------------------------- AppImage
if [ "$DO_APPIMAGE" = 1 ]; then
    TOOL="$(command -v appimagetool || true)"
    if [ -z "$TOOL" ]; then
        mkdir -p "$CACHE"
        TOOL="$CACHE/appimagetool-$ARCH.AppImage"
        if [ ! -x "$TOOL" ]; then
            log "下载 appimagetool"
            curl -fsSL -o "$TOOL" "$APPIMAGETOOL_URL"
            chmod +x "$TOOL"
        fi
    fi

    log "构建 AppImage"
    AD="$WORK/SimpleLive.AppDir"
    mkdir -p "$AD/usr/bin" "$AD/usr/share/metainfo"
    cp -R "$STAGE/opt" "$AD/"
    cp "$STAGE/applications/simple_live_app.desktop" "$AD/"
    cp "$STAGE/icons/256x256/simple_live_app.png" "$AD/simple_live_app.png"
    ln -sf simple_live_app.png "$AD/.DirIcon"
    ln -sf "../../opt/$(basename "$APPDIR_SRC")/simple_live_app" "$AD/usr/bin/simple_live_app"
    cp "$HERE/appimage/AppRun" "$AD/AppRun"
    chmod +x "$AD/AppRun"
    [ -f "$STAGE/simple_live_app.metainfo.xml" ] && cp "$STAGE/simple_live_app.metainfo.xml" "$AD/usr/share/metainfo/"

    OUT_APPIMAGE="$OUTDIR/SimpleLive-$VERSION-$ARCH.AppImage"
    ARCH="$ARCH" APPIMAGE_EXTRACT_AND_RUN="${APPIMAGE_EXTRACT_AND_RUN:-1}" \
        "$TOOL" --no-appstream "$AD" "$OUT_APPIMAGE" > "$WORK/appimagetool.log" 2>&1 \
        || { tail -20 "$WORK/appimagetool.log" >&2; die "appimagetool 失败"; }
    log "AppImage  ->  $OUT_APPIMAGE"
fi

log "完成，产物在 $OUTDIR"
ls -lh "$OUTDIR"
