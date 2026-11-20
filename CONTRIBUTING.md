# Contributing

感谢参与 dsh-switch。

## 开发环境

- Windows 10 / 11 x64
- PowerShell 5.1
- .NET Framework 4.8
- Node.js 不是必需依赖
- 修改桌面外壳时需要 WebView2 SDK（`scripts/build-app.ps1` 会自动恢复）

## 开始开发

```powershell
git clone https://github.com/<owner>/dsh-switch.git
cd dsh-switch
powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1
```

构建桌面版：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-app.ps1
```

## 修改原则

1. 不要提交 `instances.json`、`current.json`、日志、浏览器 profile 或任何真实用户目录。
2. 不要修改用户已安装的 DSH 程序文件。
3. 涉及删除、迁移、profile 切换的改动必须保留失败恢复路径。
4. 新增界面文案优先保持简洁、明确，避免把实现细节暴露给普通用户。
5. 含中文的 PowerShell 文件使用 UTF-8 BOM；纯 ASCII 的选择器脚本可保持无 BOM；`.cmd` 使用 CRLF。
6. 提交前运行 `verify.ps1`，涉及 C# 时加 `-BuildApp`。

## Pull Request

- 一个 PR 只解决一个明确问题。
- 描述复现步骤、行为变化和验证方式。
- 不附带构建产物、备份目录或编辑器配置。
- 涉及安全边界时同步更新 `SECURITY.md` 或架构文档。

## 安全漏洞

请不要在公开 Issue 中披露可利用细节，按 [SECURITY.md](SECURITY.md) 的方式私下报告。
