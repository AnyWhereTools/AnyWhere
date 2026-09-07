# 发布 AnyWhere

[English](RELEASING.md) · 简体中文 · [返回首页](../README.zh.md)

AnyWhere 的分发产物是经过 **Developer ID 签名和公证的 `.dmg`**，使用 **Sparkle** 自动更新。本文说明首次配置和每次发布的操作。

分发需要付费的 **Apple Developer Program** 会员资格和 **Developer ID Application** 证书。用于本地开发的 Apple Development 证书不能替代分发签名和公证所需的证书。

本文中的钥匙串用于开发者签名和发布工具；应用内的插件密码配置使用[本地加密存储](pack-spec.zh.md#本地保存加密与备份)，不依赖钥匙串。

## 首次配置

### 1. Developer ID 证书

在 Xcode → Settings → Accounts 或 Apple Developer 网站创建 **Developer ID Application** 证书，安装到登录钥匙串。查询签名身份：

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
# 示例：Developer ID Application: Your Name (TEAMID)
```

### 2. 公证凭据

在 App Store Connect → Users and Access → Integrations 创建 Developer 角色的 API Key，下载 `AuthKey_XXXXXX.p8`，记录 **Key ID** 和 **Issuer ID**。

本地发布可以先保存 notarytool 配置：

```bash
xcrun notarytool store-credentials anywhere-notary \
  --key AuthKey_XXXXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
# 发布时使用 NOTARY_PROFILE=anywhere-notary
```

### 3. Sparkle EdDSA 密钥

首次生成签名密钥对，私钥默认保存在登录钥匙串：

```bash
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
# 将输出的公钥填入 project.yml 的 SUPublicEDKey，替换占位值
```

供 CI 使用时，导出私钥并妥善保管：

```bash
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.pem
```

修改 `SUPublicEDKey` 后重新运行 `make gen`。

更新源为 `https://raw.githubusercontent.com/appdev/AnyWhere/main/appcast.xml`。发布产物和更新源属于当前仓库，不使用上游项目的更新源。应用默认在启动时静默检查更新，仅发现可用更新时提示；初始化错误只记录日志。更新器成功配置前，手动检查不可用。

### 4. GitHub Actions Secrets

为标签触发的 [release.yml](../.github/workflows/release.yml) 工作流配置以下仓库 Secrets，入口为 Settings → Secrets and variables → Actions：

| Secret | 内容 |
|--------|------|
| `DEVELOPER_ID_CERT_P12_BASE64` | 导出的 Developer ID 证书及私钥 `.p12`，经 Base64 编码 |
| `DEVELOPER_ID_CERT_PASSWORD` | `.p12` 导出密码 |
| `KEYCHAIN_PASSWORD` | CI 临时钥匙串的密码 |
| `DEVELOPER_ID_APP` | `Developer ID Application: Your Name (TEAMID)` |
| `TEAM_ID` | Apple Team ID |
| `NOTARY_KEY_ID` / `NOTARY_ISSUER` | 公证 API Key 的 Key ID 和 Issuer ID，分别配置 |
| `NOTARY_KEY_P8_BASE64` | `AuthKey_XXXXXX.p8` 的 Base64 内容 |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle 私钥字符串 |

证书编码示例：`base64 -i DeveloperID.p12 | pbcopy`。

## 执行发布

### 本地发布

```bash
export DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
export TEAM_ID=TEAMID
export NOTARY_PROFILE=anywhere-notary
make release VERSION=1.0.0
```

脚本会归档 Release 构建并启用 hardened runtime，导出 Developer ID 应用，制作和签名 DMG，提交公证、装订公证票据，并输出 Sparkle 签名。产物为 `build/release/AnyWhere-1.0.0.dmg`。

### 通过 CI 发布

先提交待发布改动，再创建并推送版本标签：

```bash
git tag v1.0.0
git push origin v1.0.0
```

发布脚本从标签取得版本号并覆盖构建参数 `MARKETING_VERSION`，同时生成递增构建号 `CURRENT_PROJECT_VERSION`。无需手工替换 `App/Info.plist` 中的构建变量占位符。

`release.yml` 会构建、签名、公证，创建包含 DMG 的 GitHub Release，重新生成 `appcast.xml` 并推送到 `main`。Sparkle 客户端通过 `SUFeedURL` 获取更新。

## 发布检查

- [ ] `project.yml` 中的 `SUPublicEDKey` 已替换为真实 Sparkle 公钥。
- [ ] 验证默认后台检查：发现更新时提示，没有更新或检查失败时不弹窗；手动检查仍显示结果。
- [ ] 版本标签正确，发布脚本生成的版本号与构建号符合预期。
- [ ] CI 所需的九项 GitHub Secrets 已配置。
- [ ] `xcrun stapler validate build/release/AnyWhere-<v>.dmg` 通过。
- [ ] 在干净机器上验证 Gatekeeper：`spctl -a -vvv -t install AnyWhere-<v>.dmg`。
