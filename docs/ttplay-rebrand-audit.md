# TTPlay 品牌残留审计与 GitHub 依赖评估

> 审计日期：2026-11-23
> 范围：`E:\Code\plezy`（origin `ttainet/TTPlay`，upstream `edde746/plezy`）
> 方法：全仓文本扫描（排除 `build/`、`.dart_tool/`、`.git/`、`android/app/.cxx/`、`node_modules/`）+ GitHub API 核对上游仓库与 Release 资产

## 结论摘要

1. 上一次改名提交 `63ceee82f` 只覆盖了 88 个文件：应用显示名、i18n 文案、部分平台 ID。**代码内部标识和发布链路基本没动**。实测仍有 **1446 个文件**含 `plezy`（区分大小写不敏感）。
2. 有 4 处不是"影子"而是**已经坏掉的构建/测试**：macOS CI 打包路径、iOS/macOS 单元测试的模块名、Maestro 的 `appId`、macOS `TEST_HOST`。
3. 有一处**用户可直接感知的错误行为**：应用内更新检查仍指向 `edde746/plezy`，而 CI 默认打开 `ENABLE_UPDATE_CHECK=true`，你的构建会提示"升级"到上游 Plezy。
4. GitHub 依赖**远不止一个上游**：构建期 4 个 pub git 源 + 6 个二进制仓库（Apple 侧还串联 13 个仓库、25 个 binaryTarget）；运行期 3 个上游服务 + 1 个数据仓库。
5. 你说的"Flutter 小改动单独有个 GitHub"= **`edde746/flutter-plezy`**（Windows DirectComposition 引擎补丁 + tvOS 引擎产物）。可以迁到自己 GitHub：**镜像 Release 资产即可，不建议自己编译引擎**。

## 清点数据

| 目录 | 含 `plezy` 的文件数 | 说明 |
| --- | ---: | --- |
| `test/` | 716 | 几乎全是 `import 'package:plezy/...'` |
| `lib/` | 211 | 包导入、客户端名、服务地址、注释 |
| `android/` | 184 | Kotlin 包声明、Gradle、Manifest |
| `media_library/` | 80 | Go module 路径、Web 文案 |
| `scripts/` | 48 | 发布、校验、符号上传 |
| `.maestro/` | 40 | `appId` 与实际包名不符 |
| `tvos/` | 26 | 引擎下载、构建脚本 |
| `linux/` | 23 | 二进制名、桌面文件、打包 |
| `windows/` | 19 | 安装器、引擎替换、注释 |
| `website/` | 18 | 整站仍是上游站点 |
| `ios/`、`macos/` | 15 / 14 | 产品名、测试模块 |
| `packages/`、`ui_redesign/`、`docs/` | 11 / 11 / 11 | 固定副本、设计稿、历史计划 |
| `shared/` | 7 | C++ namespace、Channel 名 |

更多量化：`test/` 里 `package:plezy/` 共 **5102 处**，`lib/` 里 **51 处**；Android `com/edde746/plezy/` 下 **147 个 Kotlin 文件**；`lib` 内硬编码 `'Plezy'` 字面量 **18 处**；i18n 共 22 个语言文件，键名仍有 `quitPlezy`、`addPlezyProfile`。

## 一、用户可见层

| 位置 | 现状 | 处理建议 |
| --- | --- | --- |
| `lib/i18n/*.i18n.json` | 显示文案已是 TTPlay，但键名 `quitPlezy`、`addPlezyProfile` 保留 | 键名可保留（不影响显示）；若追求整洁，改名后重跑 slang |
| `lib` 内 12 个文件、18 处 `'Plezy'` | 作为 Plex/Jellyfin/Emby 客户端名、User-Agent、Simkl `app-name`、局域网发现标识 | 统一改 `TTPlay`；**局域网发现要兼容双读**，见下 |
| `assets/plezy.png`、`plezy.svg`、`plezy_adaptive_foreground.svg` | 登录页、关于页、启动屏、图标选择器在用 | 重命名为 `ttplay_*`，同步 `pubspec.yaml` 和 5 处 `Image.asset`/`SvgPicture.asset` |
| `linux/packaging/com.edde746.plezy.desktop` | `Name=TTPlay`，但 `Exec=plezy`、`Icon=plezy`、`StartupWMClass=plezy` | 二进制名一起改，见"发布链路" |
| `website/` | 整站仍是 plezy.app：域名、下载地址、Play 包名 `com.edde746.plezy`、OG 图 | 不部署就删；要部署就整站改写为 play.ttai.net |
| `media_library/web/src/pages/user/*` | 4 处文案"请在 Plezy 客户端中…" | 改 TTPlay |

**局域网发现**：`lib/services/companion_remote/lan_discovery_service.dart:120` 发送 `'app': 'plezy'`，第 205 行只接受 `'plezy'`。这是配对协议字段。建议改为发送 `'ttplay'`、接收同时接受 `ttplay` 和 `plezy`，否则新旧安装互相发现不了。

**Simkl**：`lib/services/trackers/simkl/simkl_constants.dart:34` 的 `appName = 'plezy'` 会作为 `app-name` 查询参数和 UA 上报。改不改取决于你是否在意 Simkl 后台显示的应用名；改前先用一个账号验证 API 仍接受。

## 二、已经坏掉的地方（优先修）

| 问题 | 证据 | 后果 |
| --- | --- | --- |
| macOS 发布流程路径错误 | `macos/Runner/Configs/AppInfo.xcconfig` 已是 `PRODUCT_NAME = TTPlay`，但 `.github/workflows/build.yml:301/323/339/364` 仍在签名、打包 `Plezy.app` | macOS Release job 在签名阶段就找不到路径，打包失败 |
| macOS/iOS 单元测试模块名 | `macos/RunnerTests/RunnerTests.swift:5`、`ios/RunnerTests/RunnerTests.swift:7` 仍是 `@testable import Plezy`；macOS 模块名随 `PRODUCT_NAME` 变成 `TTPlay` | Apple 原生测试无法编译 |
| macOS `TEST_HOST` | `macos/Runner.xcodeproj/project.pbxproj` 三处 `Plezy.app/.../Plezy` | 测试宿主指向不存在的产物 |
| Maestro 全部流程失效 | `.maestro/**` 共 38 个流程写 `appId: com.edde746.plezy`，实际 `applicationId = com.ttainet.ttplay` | `maestro test` 无法启动应用 |
| Windows 安装器命名不一致 | `windows/build-installer.ps1:56` `OutputBaseFilename=plezy-windows-installer`，`:289/302` portable 包名 `plezy-*`，但 CMake `project(ttplay)`、`BINARY_NAME=ttplay`、`ExeName=ttplay.exe` | 产物名与 CI 断言、WinSparkle 签名对象耦合，改一处要全改 |
| iOS 产品名 | `ios/Runner.xcodeproj/project.pbxproj` `PRODUCT_NAME = Plezy`（Info.plist 显示名已是 TTPlay） | 用户看到 TTPlay，但 IPA 内是 `Plezy.app`；与 CI `cp -r .../Plezy.app` 恰好一致，改动时要同步 |

## 三、发布与分发链路

| 文件 | 仍指向上游的地方 |
| --- | --- |
| `.github/workflows/build.yml` | `RELEASE_DART_DEFINES` 用 `github.repository == 'edde746/plezy'` 决定是否启用 Sentry；产物 `plezy-android-*.tar.gz`、`plezy-ios.ipa`、`plezy-macos.dmg`、`plezy-windows-*`；`Upload symbols to bugs.plezy.app`；`Plezy.app` 路径 |
| `.github/workflows/update-packages.yml` | 从 `github.com/edde746/plezy/releases` 下载 dmg；更新 `Casks/plezy.rb`；winget `identifier: edde746.Plezy`；推 appcast 分支 |
| `Casks/plezy.rb` | 全文件：cask 名、版本源、`Plezy.app`、`com.edde746.plezy` 清理路径 |
| `.github/FUNDING.yml` | `github: edde746`、`liberapay: edde746` |
| `scripts/checks/check_build_workflow.py:59` | 断言 `plezy-windows-installer.exe` |
| `scripts/release/upload_symbols.dart:803-804` | `SENTRY_ORG`/`SENTRY_PROJECT` 默认 `plezy` |
| `linux/CMakeLists.txt` | `BINARY_NAME "plezy"`；CI `cmake --build --target plezy`；`linux/packaging/plezy.sh`、AppImage/Flatpak/包名 `plezy-linux-*` |
| `website/` | 下载按钮与校验测试全部指向 `edde746/plezy/releases/latest` |

## 四、运行时依赖上游服务（比改名更要紧）

| 位置 | 依赖 | 影响 |
| --- | --- | --- |
| `lib/services/update_service.dart:18-19` | `_githubRepo='edde746/plezy'`、`_feedUrl=cdn.jsdelivr.net/gh/edde746/plezy@appcast/appcast.xml` | **会提示安装上游 Plezy**，Sparkle/WinSparkle 还会直接下载上游 dmg |
| `lib/services/donation_service.dart:4` | `liberapay.com/edde746`，CI `ENABLE_DONATIONS=true` | 你的用户给上游作者捐款 |
| `lib/main.dart:136` | Sentry DSN `bugs.plezy.app`（`ENABLE_SENTRY` 默认 false，CI 也只在上游仓库开） | 默认不上报；但常量仍在，误开就上报到上游 |
| `lib/services/plezy_server.dart:4` | `https://ice.plezy.app`：tracker OAuth 代理 `/auth`、日志上传 `/logs`、Discord 海报 `/posters` | 上游服务停掉则 Trakt/Simkl/MAL/AniList 登录、日志上传、Discord 封面失效 |
| `lib/services/trackers/anime_mappings_store.dart:29` | 运行时从 `edde746/anime-mappings` 的 `releases/latest` 下载 2MB 数据集 | 上游停更/删库则动漫映射失效；可改为内置资产或自建仓库 |
| Watch Together | `openwatch.party` 公共 relay | 第三方服务，不属于 edde746，但同样是外部依赖 |

## 五、GitHub 依赖矩阵（实测）

| # | 仓库 | 角色 | 引用位置 | 固定方式 | 仓库大小 | Release 资产 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `edde746/plezy` | 应用上游源码 | `git remote upstream`、`docs/upstream-sync-log.md` | 按提交 cherry-pick | 274 MB | 2.26.0 共 1.26 GB / 23 个 |
| 2 | `edde746/background_downloader` | pub git 源（上游 fork，10+ 处补丁） | `pubspec.yaml:78-81` | `afa3fe6` | 67 MB | — |
| 3 | `edde746/auto_updater` | pub git 源（4 个子包） | `pubspec.yaml:83-87`、`dependency_overrides:138-152` | `9e150f7` | 39 MB | — |
| 4 | `edde746/media_controls` | pub git 源（`os_media_controls`） | `pubspec.yaml:41-44` | `a27208e` | 333 KB | — |
| 5 | `fluttercommunity/plus_plugins` | `connectivity_plus` 固定提交 | `pubspec.yaml:36-40` | `bf04cdf` | 大 | — |
| 6 | `edde746/mpv-build` | libmpv 二进制 + SwiftPM 包 | `mpv-build.lock.json`、`windows/CMakeLists.txt`、`android/app/build.gradle.kts`、`ios`/`macos` SwiftPM | `6dbda06` | 2.5 MB | 单批约 600 MB / 24–40 个 |
| 7 | `edde746/flutter-plezy` | **Flutter 引擎补丁产物**（Windows DirectComposition + tvOS） | `windows/tool/install-patched-engine.ps1:29`、`tvos/scripts/fetch_engine.sh:39` | tag `windows-v3.47.1+2` / `v3.47.1` | 648 KB | Windows 299 MB、tvOS 83 MB |
| 8 | `edde746/libdovi-builds` | Android Dolby Vision `.so` | `android/app/build.gradle.kts:228` | `v2.3.1` | 17 KB | 73 MB / 14 个 |
| 9 | `edde746/libass` | Android libass 预编译 | `android/libass/src/main/cpp/CMakeLists.txt:9` | `0.18.4` | 3.9 MB | 22 MB |
| 10 | `edde746/anime-mappings` | 运行期数据集 | `lib/services/trackers/anime_mappings_store.dart:29` | `releases/latest` | 30 KB | 2.1 MB / 每次 |
| 11 | `edde746/libdav1d-build` + `mpvkit/*`（11 个） | Apple 端 xcframework | `mpv-build` 的 `Package.swift` | 25 个 `binaryTarget` + checksum | — | 合计约数百 MB |
| 12 | `edde746/MPVKit` | 历史仓库名，仅出现在脚本与测试中 | `scripts/set_native_revision.sh`、`scripts/test_set_native_revision.py`、`tvos/scripts/test_wire_mpv.rb` | — | 1.4 MB | 仅迁移历史 |

补充：`universal_gamepad` 是 pub.dev 托管包（homepage 指向 `edde746/universal_gamepad`），不是 git 依赖；`packages/` 下的 `saf_util`、`shared_preferences_windows`、`shared_preferences_linux`、`wakelock_plus` 已经是仓库内固定副本，**不需要额外 GitHub 仓库**。

**回答"是不是只有一个上游就够"：不够。** 现状是 1 个应用上游 + 3 类外部依赖：

- 源码 fork：4 个（3 个在 edde746，1 个在 fluttercommunity）
- 二进制产物：6 个（mpv-build、flutter-plezy、libdovi、libass、libdav1d，以及 Apple 串联的 mpvkit 11 个）
- 运行期：1 个数据仓库 + 3 个上游服务（ice/bugs/appcast，外加捐款页）

## 六、Flutter 引擎这件事

`edde746/flutter-plezy` 就是你说的"Flutter 小改动单独的 GitHub"。它包含两类产物：

1. **Windows 引擎**：打了 DirectComposition 补丁，让 mpv 视频面合成在 Flutter UI 下方（同一 HWND，窗口捕获可用），并修复窗口管理器（PowerToys FancyZones）缩放导致的空白（flutter/flutter#159630）。`windows/runner/main.cpp` 依赖 `FLUTTER_WINDOWS_DCOMP`。
2. **tvOS 引擎**：Flutter 官方不支持 tvOS，`flutter-tvos` 系的引擎产物是 tvOS 构建的唯一来源，`tvos/scripts/fetch_engine.sh` 直接下载它。

**能不能放到自己 GitHub：能。** 三条路线：

| 路线 | 做法 | 成本 | 适用 |
| --- | --- | --- | --- |
| A. 镜像产物（推荐） | 建 `ttainet/flutter-engine`，把 `flutter-plezy-windows-3.47.1.zip`（299 MB）和 `flutter-tvos-3.47.1.tar.gz`（83 MB）原样上传为 Release；改 3 个常量 | 约 1 小时 + 400 MB 存储 | 不打算改引擎补丁 |
| B. 自己编译 | 克隆 `flutter-plezy`（648 KB 构建脚本），用 depot_tools 编译 Windows/tvOS 引擎 | Windows 数小时、tvOS 需 macOS + Xcode；每次 Flutter SDK 升级都要重编 | 需要修改窗口合成/引擎行为 |
| C. 放弃补丁 | 用官方引擎 | 0 | **不可行**：Windows 合成会坏，tvOS 根本编不出来 |

路线 A 要改的常量：

- `windows/tool/install-patched-engine.ps1`：`$Url`、`$Sha256`、`$ExpectedEngine`
- `tvos/scripts/fetch_engine.sh`：`RELEASES_URL` 默认值
- 注意 `$ExpectedEngine` 必须与 SDK 的 `bin/cache/engine.stamp`（当前 `5d531788…`）一致，换 Flutter 版本时三个值要一起换

## 七、自托管方案（可直接照做）

### 方案 A：最小自治（推荐，3 个仓库）

1. **把 4 个 pub git 依赖搬进 `packages/`**（`background_downloader`、`auto_updater`、`media_controls`，以及 `connectivity_plus` 单包）。之后 `pubspec.yaml` 全部用 `path:`，`pub get` 不再访问任何第三方 git 源，版本与应用同仓锁定。
   - 注意保留 `dependency_overrides` 里 `connectivity_plus` 的固定关系：`background_downloader` 9.6.2 声明依赖 hosted `connectivity_plus`，仍需 override 到本地副本。
   - 固定副本已有先例（`packages/` 4 个包），照 `wakelock_plus/provenance.json` 的格式补来源与补丁说明。
2. **`ttainet/mpv-build`**：镜像上游仓库源码（2.5 MB）+ 只保留你用到的 Release 资产（`binaries-f78e66727714` 的 Android aar、`binaries-42bac6793cc8` 的 Windows/Linux/Apple 资产）。SwiftPM 必须能从仓库解析，所以这个仓库不能省。
3. **`ttainet/ttplay-deps`**：一个仓库承载其余产物——引擎两份、libdovi、libass、anime-mappings，用不同 tag 区分。总共约 800 MB。
   - 想连 Apple 的 25 个 xcframework 也自治：把它们上传到自己的 release，然后批量替换 `Package.swift` 里的 URL（`checksum` 基于 zip 内容，改 URL 不影响校验）。

总仓库数：**应用 1 + 基础设施 2**。`edde746/plezy` 只保留为只读 `upstream` remote，随时可删。

### 方案 B：完全自治

在方案 A 基础上，再把 `mpvkit/*` 的 11 个仓库、25 个 xcframework 全部镜像，并自建 `ice.plezy.app` 的替代（tracker OAuth 代理、日志上传、Discord 海报）。适合要长期维护、对外分发的情况，一次性工作量 2–3 天。

### 方案 C：维持现状

只把地址抽成常量，接受上游删库/改 tag 的风险。当前 pub 依赖都按 commit SHA 锁定，能防 force-push，但**防不了仓库被删**。

### 迁移后要改的地址清单

| 文件 | 改动 |
| --- | --- |
| `pubspec.yaml` | 4 个 git 源 → `path: packages/...` |
| `mpv-build.lock.json` | `repo` 和 3 处 `assetBase`（用 `scripts/set_native_revision.sh` 统一改） |
| `android/app/build.gradle.kts:228` | `doviBaseUrl` |
| `android/libass/src/main/cpp/CMakeLists.txt:9` | `LIBASS_ZIP_URL` |
| `windows/tool/install-patched-engine.ps1:29` | `$Url`/`$Sha256`/`$ExpectedEngine` |
| `tvos/scripts/fetch_engine.sh:39` | 默认 `RELEASES_URL` |
| `lib/services/update_service.dart:18-19` | 仓库名 + appcast 地址 |
| `lib/services/trackers/anime_mappings_store.dart:29` | 数据集地址 |
| `lib/services/plezy_server.dart:4` | 自建代理地址，或关闭相关功能 |
| `Casks/plezy.rb`、`.github/workflows/update-packages.yml` | 发布源、cask 名、winget id、appcast 分支 |
| `website/src/lib/content/downloads.ts` | 下载源与 Play 包名 |

## 八、建议执行顺序

**第 1 批 · 修坏掉的（半天）**

1. `update_service.dart` 改成自己的仓库与 appcast；没有 appcast 就先关 `ENABLE_UPDATE_CHECK`。
2. `donation_service.dart` 删除或改自己的赞助页；CI 去掉 `ENABLE_DONATIONS`。
3. `main.dart:136` Sentry DSN 置空或改自己的项目；`upload_symbols.dart` 的 org/project 改掉。
4. macOS：`build.yml` 的 `Plezy.app` → `TTPlay.app`；`project.pbxproj` 的 `TEST_HOST`；两处 `@testable import Plezy` → `TTPlay`。
5. `.maestro/**` 的 `appId` → `com.ttainet.ttplay`（38 处，一条 sed 即可）。

**第 2 批 · 发布链路（1 天）**

6. `build.yml`：产物名统一 `ttplay-*`；Sentry 开关改成 `github.repository == 'ttainet/TTPlay'` 或直接删；符号上传目标改自己的。
7. `windows/build-installer.ps1`：`OutputBaseFilename`、portable 名、所有 `Plezy` 文案；同步 `check_build_workflow.py` 的断言。
8. Linux：`BINARY_NAME`、desktop 文件名与 `Exec`/`Icon`/`StartupWMClass`、`plezy.sh` → `ttplay.sh`、CI target、AppImage/Flatpak/包名。
9. `Casks/plezy.rb` 与 `update-packages.yml`：自用不分发就直接删；要分发就改 cask 名、URL、清理路径。
10. `.github/FUNDING.yml` 删除或改自己。

**第 3 批 · 品牌资产与文案（半天）**

11. `assets/plezy.*` 重命名 + `pubspec.yaml` + 5 处引用。
12. 18 处硬编码 `'Plezy'` 改 `TTPlay`；局域网发现改双读。
13. `website/` 决定删还是重写；`media_library/web` 4 处文案。
14. README/CONTRIBUTING/TRADEMARKS 重写（TRADEMARKS 必须去掉上游商标声明，否则公开分发违反其条款）。

**第 4 批 · 代码身份（2–3 天，风险最高，建议单独分支）**

15. Go module：`plezy/media_library` → `ttplay/media_library`（80 个文件，机械替换 + `go build ./...`）。
16. Dart 包名：`pubspec.yaml name` + 5102 处测试导入 + 51 处 lib 导入；跑 `flutter analyze` + 全量 `flutter test`。
17. Android：`namespace`、Kotlin 目录 `com/edde746/plezy` → `com/ttainet/ttplay`、`PlezyActivity` 类名、Manifest `targetActivity`、androidTest 引用；必须真机跑一遍。
18. C++ namespace/头文件保护、CMake 选项 `PLEZY_*`、环境变量 `PLEZY_*`：可选，收益最低。
19. MethodChannel 名 `com.plezy/*`：**建议不改**，Dart 与原生必须同时改，出错就是运行时崩溃。

## 九、风险与注意

- **applicationId 已经改成 `com.ttainet.ttplay`**：老的 `com.edde746.plezy` 安装无法覆盖升级，应用数据不会迁移。自用无所谓；如果已有用户，得保留旧包名一个版本做数据迁移。
- **Dart 包名改动会放大上游 cherry-pick 冲突**：`test/` 有 5102 处 `package:plezy`，上游补丁只要碰到测试文件就容易冲突。建议放到最后，或接受"上游同步时手工解冲突"。
- **GPL-3.0**：自托管二进制自用没问题；一旦对外分发，需要同时提供对应源码（mpv、libass、libdovi 等）并保留版权声明。
- **商标**：`TRADEMARKS.md` 明确要求公开分发必须换名。现在残留的 Plezy 字样在公开发布前必须清完，尤其是 App 内客户端名和网站。
- **GitHub 仓库关系**：`ttainet/TTPlay` 目前仍是 `edde746/plezy` 的 fork（API `fork=true`），页面会显示 "forked from edde746/plezy"。GitHub 不允许 fork 私有化，要彻底断开只能联系 GitHub Support 解绑。
- **Release 存储**：GitHub 单文件上限 2 GB，仓库建议不超过 5 GB。引擎每个 Flutter 版本约 380 MB，累积后要清理旧 tag 的资产。

## 十、复核命令

```powershell
# 全仓残留（排除生成目录）
Get-ChildItem E:\Code\plezy -Recurse -File -Force |
  Where-Object { $_.FullName -notmatch '\\(build|\.dart_tool|\.git|\.cxx|node_modules)\\' -and
                 $_.Extension -notin @('.png','.jpg','.webp','.ttf','.bin','.so','.aar','.jar') } |
  Select-String -Pattern 'plezy' -SimpleMatch -List |
  ForEach-Object { $_.Path.Replace('E:\Code\plezy\','') }

# 只查"会被用户看到"的硬编码
Select-String E:\Code\plezy\lib -Include *.dart -Pattern "'Plezy'" -Recurse

# 查外部 GitHub 地址
Select-String E:\Code\plezy -Include *.yaml,*.yml,*.dart,*.kts,*.json,*.ps1,*.sh -Pattern 'github\.com/edde746' -Recurse
```
