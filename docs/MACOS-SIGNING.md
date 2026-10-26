# 共享签名配置

free-jolan-apps 的 macOS 应用统一使用组织级凭据。新仓库的 Owner 选择该组织，即可在发版工作流中引用已有 Secrets，无需重新上传证书或填写密码。

## 组织配置

组织 Settings → Secrets and variables → Actions 中配置以下六项，Repository access 设为 All repositories：

| Secret | 内容 |
| --- | --- |
| APPLE_CERTIFICATE | Developer ID Application 证书及私钥的 .p12 Base64 |
| APPLE_CERTIFICATE_PASSWORD | .p12 导出密码 |
| APPLE_SIGNING_IDENTITY | Developer ID Application 签名身份全名 |
| APPLE_TEAM_ID | Apple Developer Team ID |
| APPLE_ID | 公证使用的 Apple 账号 |
| APPLE_PASSWORD | 该账号的 App 专用密码 |

凭据续期或更换时在组织中更新一次，各应用后续发版读取新值。同名仓库或环境 Secret 会覆盖组织值，迁移已有应用时需要检查。免费组织的私有仓库不能使用组织级 Secrets；公开仓库可用，私有仓库需相应组织付费套餐。

All repositories 允许组织内全部仓库的工作流使用这些凭据，因此该组织只放可信的应用项目和发版代码。PR 与开发检查不需要传入签名 Secrets。

## 新应用接入

每个应用负责构建并组装自己的 .app，然后调用本仓库的通用组件。以下步骤放在受信任的版本标签发版任务中，runner 使用 GitHub 托管的 macOS。其他项目可将版本引用固定为已验证的完整提交 SHA。

```yaml
- uses: free-jolan-apps/jotlet/.github/actions/sign-notarize@v0.2.4
  with:
    app: dist/YourApp.app
    certificate: ${{ secrets.APPLE_CERTIFICATE }}
    certificate-password: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
    signing-identity: ${{ secrets.APPLE_SIGNING_IDENTITY }}
    team-id: ${{ secrets.APPLE_TEAM_ID }}
    apple-id: ${{ secrets.APPLE_ID }}
    apple-password: ${{ secrets.APPLE_PASSWORD }}
    # entitlements: packaging/release.entitlements
```

组件签名主应用、核对所有架构的 Team ID、hardened runtime 和 secure timestamp，然后提交公证、附加票据并执行 Gatekeeper 校验。它不会修改 Info.plist、应用名称或标识符，也不打包或发布 Release。调用方在组件成功后创建最终 ZIP，确保附加的公证票据进入下载包。

包含 Framework、扩展、Helper 或其他嵌套代码的应用，应先由各自构建工具按从内到外的顺序完成签名。需要 entitlements 的主应用显式传入发布专用 plist，避免携带调试权限。Tauri 等框架已有完整签名支持时，也可直接使用同一套组织级 APPLE_* 凭据，无需改用这个组件。

可复用工作流需要调用方显式传递 Secrets；在同一组织中可使用 `secrets: inherit`，或只传入所需的六项。仅创建一个存有 Secrets 的公共工作流仓库不会让个人账号下的其他仓库自动获得凭据。

## 参考

- [GitHub 组织级 Secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)
- [Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
