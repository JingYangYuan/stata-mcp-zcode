# stata-mcp

一键部署 [stata-mcp](https://github.com/hanlulong/stata-mcp)（DeepEcon.stata-mcp）到 **ZCode** 与 **Oh My Pi (omp)** 全局配置的部署仓库。支持 **macOS (Apple Silicon / Intel)** 与 **Windows 10/11**。克隆后运行一个脚本即可完成全部安装，无需手动配置，不污染其他任何现有配置。

## 架构

stata-mcp 官方形态是 VS Code 扩展，MCP 服务器由扩展托管（VS Code 必须常开）。本仓库提供**独立后台服务 + 代理免疫的 stdio 桥接**部署：

```text
               ┌───────────────────────┐
               │ ZCode / Oh My Pi 会话 │
               └───────────┬───────────┘
                           │
       ┌───────────────────┴───────────────────┐
       ▼ (HTTP 传输，ZCode 内部)                 ▼ (stdio 桥接，OMP / Claude / 终端)
http://localhost:4001/mcp-streamable    ~/.local/bin/stata-mcp (stdio bridge)
       │                                       │ (自动绕过 HTTP_PROXY/Clash 502)
       └───────────────────┬───────────────────┘
                           ▼
             stata-mcp 独立服务 (端口 4001)
                           ▼
                    本地 Stata 17+
```

### 核心优势
1. **VS Code 不需要打开**：服务脱离 IDE 独立常驻，通过进程钩子或 LaunchAgent 自动按需拉起。
2. **终端代理免疫 (Proxy-Immune)**：开发机开启 Clash / Mihomo / Surge（设置了 `HTTP_PROXY=127.0.0.1:7890`）时，stdio 桥接采用 `trust_env=False` 直连本地服务，彻底杜绝 `502 Bad Gateway` 回环报错。
3. **无损合并 (Zero Interference)**：部署脚本仅增量合并 `stata-mcp`，原样保留既有的 API Key、其他 MCP 服务器（Exa、Zotero 等）及模型配置。

---

## 前提条件

| 依赖 | 说明 |
|---|---|
| **操作系统** | macOS (Apple Silicon / Intel) 或 Windows 10/11 |
| **Stata 17+** | macOS 默认 `/Applications/Stata`；Windows 默认 `E:\Stata18`（可指定） |
| **VS Code / Cursor** | 用于获取扩展代码包与 Stata 接口模块（运行时无需开启） |
| **uv** | 缺失时脚本会自动安装 |
| **ZCode / OMP** | 已安装并初始化至少一次 |

---

## 一键部署

### macOS / Linux

```bash
git clone https://github.com/JingYangYuan/stata-mcp.git
cd stata-mcp
./deploy.sh                                          # 默认 Stata 在 /Applications/Stata
# 或显式指定路径与端口：
./deploy.sh --stata-path /Applications/Stata --port 4001
```

### Windows

```powershell
git clone https://github.com/JingYangYuan/stata-mcp.git
cd stata-mcp
powershell -ExecutionPolicy Bypass -File deploy.ps1                          # 默认 Stata 在 E:\Stata18
# 或显式指定路径与端口：
powershell -ExecutionPolicy Bypass -File deploy.ps1 -StataPath "D:\Stata21" -Port 4001
```

脚本具有完全幂等性，已安装部分自动跳过。

---

## 部署产物与配置位置

1. **服务启动脚本**：
   - macOS: `~/.zcode/scripts/stata-mcp-start.sh`（内置 `--noproxy "*"` 探测，秒级就绪）
   - Windows: `%USERPROFILE%\.zcode\scripts\stata-mcp-start.ps1`
2. **代理免疫 stdio 桥接命令**：
   - `~/.local/bin/stata-mcp`（可直接供 OMP、Claude Code、Codex 的 `type: "stdio"` 接入）
3. **宿主配置自动合并**：
   - **ZCode** (`~/.zcode/cli/config.json`)：注册 `mcp.servers["stata-mcp"]` 与 `SessionStart` 钩子。
   - **Oh My Pi** (`~/.omp/agent/mcp.json`)：注册 `mcpServers["stata-mcp"]`（采用 stdio 桥接模式，避开环境变量冲突）。
4. **服务日志**：
   - macOS: `/tmp/stata-mcp-standalone.log`
   - Windows: `%TEMP%\stata-mcp-standalone.log`

---

## 使用

在 ZCode 或 Oh My Pi 中直接使用自然语言驱动 Stata：

- 「对 dataset.dta 做描述统计并导出表格」
- 「运行 01_baseline.do 并输出回归结果」

### 暴露工具列表
- `stata_run_selection`：运行 Stata 代码片段并返回输出。
- `stata_run_file`：运行 `.do` 文件（支持超时与工作目录控制）。
- `stata_session`：会话管理（list / destroy，支持多会话隔离）。

---

## 常见问题与排查

1. **终端开启网络代理后连接显示 502**：
   - 本项目通过 `stata-mcp` stdio 桥接彻底解决该问题，确保 `~/.omp/agent/mcp.json` 中配置指向 `~/.local/bin/stata-mcp` 即可。
2. **端口占用**：
   - 默认端口 4001，与 VS Code 官方默认的 4000 互不冲突。若需修改，重新运行部署脚本时传入 `--port <新端口>` 即可。
3. **健康检查验证**：
   ```bash
   curl --noproxy "*" -s http://127.0.0.1:4001/health
   # 预期输出: {"status":"ok","service":"Stata MCP Server",...}
   ```

---

## 致谢

- [hanlulong/stata-mcp](https://github.com/hanlulong/stata-mcp)（DeepEcon 团队）— MCP 服务器本体
