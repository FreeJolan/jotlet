# 发版说明

目前输出 Universal ZIP，支持 macOS 14 及以上，包含 arm64 和 x86_64 两种架构。打包沿用本地内测的 ad-hoc 签名，尚未接入 Developer ID 和 Apple 公证，不需要配置 Apple 账号或证书即可运行。

## 提交与检查

日常改动通过 Pull Request 合并到 `main`。`CI` 会在 GitHub 托管的 macOS 15 Apple Silicon、Intel 两台虚拟机上执行 Python 发版工具测试、Swift 单元测试及原生编辑检查，再构建 Universal 应用。

原生检查只在 GitHub 托管的一次性 runner 上直接运行。开发者本机继续使用 `./scripts/test-tart.sh`。焦点、窗口顺序、外部点击、多显示器及多个桌面不属于 CI 编辑检查，涉及这些行为的改动仍需查看 Tart 截图并实际操作验证。

测试日志和发版文件在对应 Actions run 的 Artifacts 中保留 14 天。PR 只拥有读取源码的权限，写入 Release 的权限只给发布步骤。Actions 依赖固定到完整提交 SHA，Dependabot 每月检查更新。

## 创建版本

1. 更新 `packaging/Info.plist` 中的 `CFBundleShortVersionString`，格式为 `主版本.次版本.修订号`；同时递增 `CFBundleVersion` 整数构建号。
2. 在 `CHANGELOG.md` 添加该版本的 `## [版本号]` 段落，写出用户可感知的变化。
3. 提交 PR，等待 CI 通过，合并到 `main`。窗口或编辑行为有变化时，先完成 Tart 检查。
4. 确认本地 `main` 已同步，创建并推送标签。

```sh
git switch main
git pull --ff-only
git tag -a v0.2.4 -m "Jotlet v0.2.4"
git push origin v0.2.4
```

标签必须与应用版本一致，也支持 `v1.0.0-beta.1` 这样的预发布标签。0.x 版本及带预发布后缀的标签会标记为 prerelease。标签指向的提交必须已合并到 `main`。版本、更新记录、标签或工作区不一致时，流程会失败。

## 发布草稿

推送标签会触发 `Release`。它会重新检查两种架构，再打包、解压验证，最后生成草稿，包含：

- `Jotlet-v版本号-universal.zip`：应用包。
- `SHA256SUMS`：ZIP 和元数据的 SHA-256。
- `release.json`：版本、构建号、最低系统、架构、源码提交和签名状态。

更新记录自动写入草稿说明，附上安装方法和未公证的说明。核对版本与说明，下载并验证安装包后，点击 GitHub 的 Publish release。草稿在发布前仅仓库维护者可见。

```sh
shasum -a 256 -c SHA256SUMS
```

更新应用时，正常退出正在运行的旧版，备份需要保留的数据后再替换。用户资料库位于 `~/Library/Application Support/Jotlet`，不放进发布包。

## 重试和回退

构建失败时，修复原因后重试。短暂网络故障可直接重跑失败任务，或在 Actions → Release → Run workflow 中填写已有标签。标签已经对应发布版本时，应通过新版本修复，不移动已公开标签。

已有同名草稿时，重跑会更新草稿附件和说明。已有公开 Release 时，流程拒绝覆盖附件，避免同一版本下载到不同的二进制。回退应用可以从旧 Release 下载包；涉及资料库格式的变化应先备份，当前版本继续使用相同的 RTFD 与索引格式。

## 本地验证打包

以下命令只构建和校验文件，不启动应用窗口：

```sh
python3 -m unittest discover -s Tests/ReleaseToolsTests -v
./scripts/build.sh --universal
python3 scripts/release.py check
python3 scripts/release.py package
python3 scripts/release.py verify
```

输出在 `dist/release/`。`--tag v0.2.4` 会额外要求标签指向当前提交且工作区干净，供正式发版使用。

## Developer ID 与公证

目前仓库没有 Apple 开发者证书或公证凭据。ad-hoc 校验能检查包是否完整，不能证明开发者身份，也不能替代 Gatekeeper 公证。

后续如需直接向普通用户分发，可接入 Developer ID Application 签名、hardened runtime、Apple 公证和 stapling，再把 `release.json` 的签名状态改为实际结果。证书及凭据应存入 GitHub Actions secrets，不能提交到仓库。当前流程不会绕过系统安全检查。
