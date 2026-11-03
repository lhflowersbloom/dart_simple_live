# Linux 打包（RPM / AppImage）

上游只发 Linux 的 `.deb` 和 `.zip`，这里提供把它们转成 **RPM** 与 **AppImage** 的脚本。

**不重新编译任何代码**：二进制与官方发行包完全一致，脚本只做三件事——
解包、重新组织文件布局（`/opt/simple_live_app` + 桌面项 + 图标）、补充 RPM 依赖声明与 AppStream 元数据。

## 快速使用

```bash
# 依赖：Fedora  sudo dnf install rpm-build ar tar zstd curl
#       Debian  sudo apt install rpm binutils tar zstd curl
./packaging/linux/build-linux-packages.sh \
    --deb simple_live_app-1.13.2+11302-linux.deb \
    --outdir dist
```

产物：

```
dist/simple-live-1.13.2-1.x86_64.rpm
dist/SimpleLive-1.13.2-x86_64.AppImage
```

常用参数：

| 参数 | 说明 |
| --- | --- |
| `--deb <file>` | 必填，官方 Linux deb |
| `--version <ver>` | RPM 版本，默认从 deb 的 `control` 推导（取 `1.13.2+11302` 的 `1.13.2`） |
| `--release <n>` | RPM 发行号，修 bug 重发时递增（默认 1） |
| `--outdir <dir>` | 输出目录，默认 `dist` |
| `--skip-rpm` / `--skip-appimage` | 只做其中一种 |

`appimagetool` 不存在时会自动下载到 `~/.cache/simple-live-packaging/`。

## 安装

```bash
# RPM（Fedora / RHEL / openSUSE）
sudo dnf install ./dist/simple-live-*.rpm
# 依赖里的 libmpv.so.2 由 mpv-libs 提供，dnf 会自动拉取

# AppImage（任意发行版，需要系统有 libmpv.so.2）
chmod +x dist/SimpleLive-*.AppImage && ./dist/SimpleLive-*.AppImage
```

## 目录说明

```
packaging/linux/
├── build-linux-packages.sh      # 主脚本：deb → rpm + AppImage
├── rpm/
│   ├── simple-live.spec.in      # RPM 打包模板（@VERSION@/@RELEASE@/@DATE@ 由脚本替换）
│   ├── simple_live_app.desktop  # 桌面项（含中文名、AV 分类、WM class）
│   └── simple_live_app.metainfo.xml  # AppStream 元数据
└── appimage/
    └── AppRun                   # AppImage 启动器（含 libmpv 缺失检测）
```

## 几点经验

- **必须显式 `umask 022`**：`rpmbuild` 的 `%install` 默认 `umask 077`，不设的话文件会被打成 `0600`、
  主程序 `0700`，普通用户从菜单启动会报"缺少可执行权限"，`flutter_assets` 也读不到。
- **不要 strip**：Flutter 的 `libapp.so` 里是 Dart AOT 快照，`brp-strip` 会把它弄坏，
  所以 spec 里把 `%__strip` 设为 `/bin/true`。
- **依赖写 soname**（`libgtk-3.so.0()(64bit)`）而不是发行版包名，这样 Fedora / openSUSE 都能解析。
- **AppImage 不内置 mpv/ffmpeg**：新发行版编译的 ffmpeg 会依赖很新的 glibc，
  塞进 AppImage 反而只能在最新系统上跑；让系统提供 `libmpv.so.2` 更通用，缺失时 AppRun 会弹窗提示。
- 若报 `No suitable fusermount binary found`，装 `fuse-libs`（Debian 系 `libfuse2`），
  或用 `APPIMAGE_EXTRACT_AND_RUN=1 ./SimpleLive-*.AppImage`。

## 自动化

`.github/workflows/publish_linux_rpm_appimage.yml` 会在手动触发时：
下载指定 tag 的 release 里的 `.deb` → 转成 RPM + AppImage → 上传回同一个 release。
