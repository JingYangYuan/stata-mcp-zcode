# stata-mcp-zcode

在 Windows 上一键部署 [stata-mcp](https://github.com/hanlulong/stata-mcp)（DeepEcon.stata-mcp）到 [ZCode](https://zcode.ai) 全局配置的部署仓库。克隆后运行一个脚本即可完成全部安装，无需手动配置。

## 架构

stata-mcp 官方形态是 VS Code 扩展，MCP 服务器由扩展托管（VS Code 必须常开）。本仓库改为**独立后台服务**部署：

```
打开 ZCode
   │  SessionStart hook（hooks.enabled: true）
   ▼
~/.zcode/scripts/stata-mcp-start.ps1
   │  检测 http://localhost:4001/health，未运行则用扩展自带 venv 拉起服务
   ▼
stata-mcp 独立服务（localhost:4001，隐藏窗口，日志在 %TEMP%\stata-mcp-standalone.log）
   ▲
   │  ZCode 全局配置 mcp.servers["stata-mcp"] → http://localhost:4001/mcp-streamable
ZCode 会话中直接使用 stata_run_selection / stata_run_file / stata_session
```

好处：**VS Code 不需要打开**；服务只在用 ZCode 时按需启动（一次开机仅第一次启动时等待约 10 秒）。

## 前提条件

| 依赖 | 说明 |
|---|---|
| Windows 10/11 | 脚本使用 PowerShell 5.1（系统自带） |
| Stata 17+ | 默认路径 `E:\Stata18`，其他位置用 `-StataPath` 参数指定 |
| VS Code | 用于安装扩展本体（扩展提供服务器代码和 Stata 集成） |
| [uv](https://docs.astral.sh/uv/) | 缺失时脚本会自动安装 |
| ZCode | 已安装并至少成功启动过一次 |

## 一键部署

```powershell
git clone https://github.com/JingYangYuan/stata-mcp-zcode.git
cd stata-mcp-zcode
powershell -ExecutionPolicy Bypass -File deploy.ps1                          # 默认 Stata 在 E:\Stata18
# 或指定 Stata 路径 / 端口：
powershell -ExecutionPolicy Bypass -File deploy.ps1 -StataPath "D:\Stata21" -Port 4001
```

脚本可重复运行（幂等）：已安装的部分自动跳过。

### 部署内容

1. 检查 Stata 可执行文件
2. 检查/安装 uv
3. 安装 VS Code 扩展 `DeepEcon.stata-mcp`
4. 预构建扩展的 Python 3.11 虚拟环境（官方方式首次运行时要下载 Python + 依赖，本脚本提前完成，服务可秒级启动）
5. 安装 hook 脚本到 `%USERPROFILE%\.zcode\scripts\stata-mcp-start.ps1`
6. 合并写入 `%USERPROFILE%\.zcode\cli\config.json`：
   - `mcp.servers["stata-mcp"]` → `http://localhost:<port>/mcp-streamable`
   - `hooks.events.SessionStart` → 启动脚本（`hooks.enabled: true`）
   - **只新增/更新这两处，不碰配置文件中的其他任何内容**（其他 MCP 服务器、API Key 等原样保留）
7. 立即启动服务并做健康检查

完成后**打开一个新的 ZCode 会话**即可使用。

## 使用

部署后直接在 ZCode 里用自然语言指挥 Stata，例如：

- 「用 Stata 跑一下 regression.do」
- 「对 data.dta 做描述性统计并导出表格」

可用工具：`stata_run_selection`（运行代码片段）、`stata_run_file`（运行 do 文件）、`stata_session`（会话管理）。

## 常见问题

- **ZCode 里 stata-mcp 显示未连接**：开个新会话，或在 设置 → MCP 里手动重连。服务就绪需要几秒，hook 会等到就绪才返回。
- **端口冲突**：独立服务默认用 4001，与 VS Code 扩展默认的 4000 互不干扰；两边同时开也不冲突。
- **服务日志**：`%TEMP%\stata-mcp-standalone.log`。
- **不想用 hook，想开机常驻**：把同一脚本加入任务计划程序的"登录时启动"即可。
- **卸载**：删除 `%USERPROFILE%\.zcode\scripts\stata-mcp-start.ps1`，并从 `~/.zcode/cli/config.json` 移除 `mcp.servers["stata-mcp"]` 与对应的 SessionStart hook 条目。

## 致谢

- [hanlulong/stata-mcp](https://github.com/hanlulong/stata-mcp)（DeepEcon 团队）— 本仓库部署的 MCP 服务器本体
