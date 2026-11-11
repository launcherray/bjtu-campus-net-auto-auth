# 安全与隐私

## 报告安全问题

维护者： [launcherray](https://github.com/launcherray)

涉及凭据泄露、权限问题或其他安全风险，请发送邮件至 [25110704@bjtu.edu.cn](mailto:25110704@bjtu.edu.cn)，避免在公开 Issue 中披露可用凭据或完整利用细节。普通使用问题请提交 [GitHub Issues](https://github.com/launcherray/bjtu-campus-net-auto-auth/issues)。

建议说明受影响的提交或版本、Windows 环境、问题现象、脱敏后的复现步骤及可能影响。不要发送真实密码、完整凭据文件或完整登录请求 URL。维护者未承诺固定响应时间。

## 当前保护方式与边界

- 认证信息在本机输入，以 Windows DPAPI `LocalMachine` 模式加密保存。凭据目录通过访问控制仅允许 SYSTEM 和管理员访问。
- `LocalMachine` 保护与机器环境相关，不等于仅某个 Windows 用户能够解密；取得文件读取权限并拥有相应本机权限的进程可能读取凭据。请妥善保护管理员账号和计算机。
- 认证时需要向 `login.bjtu.edu.cn` 提交账号密码。代码使用 HTTPS，未添加跳过证书验证的逻辑，也没有向作者服务器发送数据的逻辑。
- 当前服务端请求格式使认证参数出现在请求 URL 中。服务端或网络调试记录可能包含这些参数，不要公开完整请求 URL、浏览器网络导出文件或抓包文件。
- 日志仅用于本机展示最近一次运行状态，当前代码不主动记录账号、密码或完整认证请求 URL。
- 本工具使用正常认证流程，不提供绕过验证码、计费或访问控制的功能。登录服务的公开页面和请求可被观察，不表示服务提供方承诺第三方 API 兼容性。

关于 DPAPI 模式，可参阅 [Microsoft DataProtectionScope 文档](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.dataprotectionscope)。

## 避免意外公开凭据

不要提交 `private/`、`credential.bin`、日志、临时文件、抓包文件或含认证数据的截图。本仓库的 `.gitignore` 覆盖常见本地文件，但不会清除已经被 Git 跟踪的内容，也不能阻止浏览器手动上传。

如果真实密码曾公开，请先更换密码，再处理文件、提交历史和相关副本。只删除最新提交中的文件不足以清除历史记录。可参考 [GitHub 敏感数据处理文档](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)。

## 维护范围

本项目由个人维护，暂未承诺特定版本的安全更新期限。反馈时请注明所用提交；更新前请阅读当前 README，并核对源码变更。
