# ENSO 监测工作台

抓取 NOAA/CPC 的官方 ENSO 指数，生成一份**自包含的单文件 HTML 仪表盘**（离线可看，可直接发给别人）。

## 目录

```
enso/
├─ scripts/
│  ├─ Update-EnsoData.ps1       抓取 + 解析 + 生成 HTML/CSV（主脚本）
│  ├─ dashboard.template.html   网页版模板：样式、结构、全部交互都在这里（改版只动它）
│  ├─ Publish-ToGitHub.ps1      走 GitHub API 发布到仓库（等价 git push，绕开被阻断的 github.com）
│  ├─ Auto-Update-Web.ps1       计划任务用的串联脚本：抓数 → 自检 → 发布
│  ├─ build-basemap.mjs         生成简化世界陆地底图（Natural Earth 110m → SVG path）
│  ├─ serve-report.mjs          本地静态服务器，用于在浏览器里查看报告
│  └─ verify-report.mjs         报告自检（35 项：数据渲染、地图、时间轴缩放/平移/点击、动画降级、页脚）
├─ assets/
│  └─ qrcode.jpg                课题组公众号二维码（页脚用，入库，生成时 base64 内嵌）
├─ docs/
│  └─ index.html                GitHub Pages 发布副本（含 .nojekyll）
├─ report/
│  └─ enso_dashboard.html       生成的仪表盘（自包含，双击即可打开；本地预览用，不入库）
├─ backup/
│  └─ web-v1-baseline-20261015/ 前端优化版之前的网页版快照，含回滚说明 RESTORE.md
├─ data/
│  ├─ raw/                      原始文件 + _meta.json（源站 Last-Modified）+ maps/（CPC 全球回归图）
│  └─ processed/
│     ├─ nino_weekly.csv        周 Niño 区指数（SST、距平、相对距平）
│     ├─ enso_monthly.csv       逐月相对 Niño3.4（RONI 口径）与 SOI
│     └─ basemap.txt            陆地轮廓 path 数据
└─ README.md
```

> 本仓库**只负责网页版**：抓数 → 生成自包含单文件 → 发布到 GitHub Pages。
> `scripts/dashboard.template.html` 是**唯一**的网页版样式与交互来源；
> `Update-EnsoData.ps1` 只负责抓数、解析、把 `__ENSO_DATA__` 替换成 JSON 后写文件，
> 改版时不需要（也不应该）碰 PowerShell 里的引号转义规则。


## 快速开始

```powershell
# 联网抓最新数据并重建（**默认同时刷新 report\ 与 docs\**）
powershell -ExecutionPolicy Bypass -File .\scripts\Update-EnsoData.ps1

# 只改模板/样式、不联网，用缓存重建（同样会刷新两份）
powershell -ExecutionPolicy Bypass -File .\scripts\Update-EnsoData.ps1 -NoDownload

# 只想更新本地报告、不碰线上副本时
powershell -ExecutionPolicy Bypass -File .\scripts\Update-EnsoData.ps1 -NoDownload -NoPublish

# 生成后自动打开
powershell -ExecutionPolicy Bypass -File .\scripts\Update-EnsoData.ps1 -Open

# 本地预览（用 http 打开更稳，画布与链接行为一致）
node .\scripts\serve-report.mjs . 8899      # → http://127.0.0.1:8899/

# 自检（35 项：数据渲染、地图、内嵌图、时间轴缩放/平移/点击定位、动画降级、页脚）
node .\scripts\verify-report.mjs
node .\scripts\verify-report.mjs docs\index.html    # 发布副本也过一遍
```

> `-PublishDir` 的默认值就是 `docs`。这是刻意的：`report\enso_dashboard.html`（本地预览，不入库）
> 与 `docs\index.html`（Pages 唯一源，入库）必须**始终同源**，
> 否则一次「只跑生成器、没带参数」就会让线上停在上一周的数据。
> 不要再写成 `-PublishDir docs` 来"提醒自己"——默认已经有了。

要求：Windows PowerShell 5.1 或以上；Node 仅用于底图、预览与自检。

## 页面功能

| 区块 | 说明 |
|---|---|
| 指标卡片 | 周 Niño1+2 / 3 / 3.4 距平、Niño3.4 相对值、El Niño 概率、官方状态 |
| 官方结论 | 实时解析 CPC 诊断页的状态、Synopsis 原文与下次发布日期 |
| 周 Niño 区海面温度 | **可缩放时间轴**折线图（五条序列，内嵌 1981-09 起全部周数据）+ 最近 8 周明细表 |
| **典型受影响区域（预报地图）** | 自绘全球影响区地图（**DJF / JJA 可切换**）+ 官方 CPC 全球回归图（温/降水，内嵌） |
| 月度相对 Niño3.4 | **可缩放时间轴**柱状图（内嵌 1950-01 起全部月度数据） |
| RONI 分位展望 | P50 中位线 + P5–P95 区间扇形图（9 个季节，点少故不缩放） |
| 概率 / 指数 / 数据源 | El Niño–中性–La Niña 概率（条带 + 表格）、ONI 与 RONI 季节值、数据源更新节奏 |

### 前端优化版（nature 视觉 + 一镜到底）

网页版在 2026-10-15 做过一次整体改版，视觉与动效全部重写，功能与数据口径不变：

| 项 | 说明 |
|---|---|
| 视觉体系 | 雨林／深海色调（青苔、翡翠、海水、暖陶土），玻璃拟态面板、衬线大标题、环境光晕 + 地形剪影 |
| 首屏 | 环表（ring gauge）把 Niño3.4 距平映射成 −2…+2 的弧长，带刻度、状态胶囊与关键数值 |
| 一镜到底 | 整页是一条连续镜头：顶部进度条、右侧章节脊柱（9 幕）、左下单幕字幕、地形视差；**镜头随滚动推进，不提供自动播放按钮** |
| 逐幕揭示 | `IntersectionObserver` 点亮 `section / 卡片 / 表格行`，只在进入视口时触发一次 |
| 图表生长 | 时间轴进入视口时曲线/柱体沿时间轴"生长"一次（1500 ms），之后交回完全手动交互 |
| 地图巡航 | 镜头在 13（DJF）/ 10（JJA）个影响区之间用 `viewBox` 补间连续推拉，标记脉冲、表格行联动；可「暂停 / 继续」或「看全球」，鼠标悬停自动让位 |
| 全屏看图 | 周指数图右上角「全屏」，铺满视口后复位、重绘 |
| 移动端 | 新增双指捏合缩放与单指拖动平移；`touch-action:pan-y` 保留页面纵向滚动 |
| 降级 | `prefers-reduced-motion` 或缺少 `requestAnimationFrame` / `IntersectionObserver` 时自动关闭动画，页面退化为「静态全显」，内容与交互完全不受影响 |
| 版式 | 两列栅格统一 `align-items:start`：默认的 `stretch` 会把短的一列拉到和高的一列同高，列表下方就会挂出一大片空白。影响区列表**完整展开、不设内部滚动** |

改版涉及的三个文件：

| 文件 | 作用 |
|---|---|
| `scripts/dashboard.template.html` | 样式、结构、全部交互（唯一来源） |
| `scripts/Update-EnsoData.ps1` | 读取模板 → 替换 `__ENSO_DATA__` → 写 `report/` 与 `docs/` |
| `scripts/verify-report.mjs` | 35 项自检；新增「动画降级不破坏渲染」的回归口径 |

回滚：`backup/web-v1-baseline-20261015/`（含 `RESTORE.md`），或 `git checkout d3d23cf -- scripts/Update-EnsoData.ps1`。


### 时间窗口与交互

两个时间序列图都能按年数切换窗口，窗口右端始终对齐最新数据：

| 图 | 年数按钮 | 默认 |
|---|---|---|
| 周 Niño 区距平 | 1 / 3 / 5 / 10 / 20 年 / 全部 | 3 年 |
| 月度相对 Niño3.4 | 1 / 5 / 10 / 30 年 / 全部 | 10 年 |

| 操作 | 效果 |
|---|---|
| 年数按钮 | 直接切到"最近 N 年"（全部 = 图上所有历史） |
| 滚轮 | 以光标位置为锚点自由缩放（最少保留 8 个点） |
| 按住拖动 | 平移时间窗 |
| 单击 | 定位并**常显该点日期与各序列数值**（再点同一点取消） |
| 移动鼠标 | 跟随显示日期与数值提示 |
| 双击 / 「复位」按钮 | 回到该图的默认年数窗口 |

读数条实时显示"窗口 起 → 止（n / 总点数）"，单击后追加"▍选中 YYYY-MM-DD"；分区标题里写明实际数据跨度（周：1981-09-02 起；月：1950-01 起）。

**可用的最长窗口就是数据本身的长度**：周指数 1981-09 起（约 45 年，逐周增长），月度指数 1950-01 起（约 76 年，逐月增长）。原始文件本身还有更长历史时，把 `Update-EnsoData.ps1` 里 `$chartWeeks` / `$spanMonths` 的范围放宽即可。

> 这里刻意**不写具体条数**——它每周/每月都在涨，写死必然过期（曾经写死"2353 周"，数据涨到 2354 周就对不上了）。
> 要看当前条数，直接看页头副标题（由脚本注入），或：
> `node -e "const t=require('fs').readFileSync('docs/index.html','utf8');console.log(/\"span\":\{[^}]*\}/.exec(t)[0])"`

## 数据源与更新节奏

| 时效 | 来源 | 节奏 | 入口 |
|---|---|---|---|
| 最快 | **NOAA CPC 周指数**（本报告主数据） | 每周（实测多为周四/周五） | [wksst9120.for](https://www.cpc.ncep.noaa.gov/data/indices/wksst9120.for) · [周度监测页](https://www.cpc.ncep.noaa.gov/products/precip/CWlink/MJO/enso.shtml) |
| 月 | CPC 官方诊断（定级 / Advisory） | 每月第二个周四 | [ENSO Diagnostic Discussion](https://www.cpc.ncep.noaa.gov/products/analysis_monitoring/enso_advisory/ensodisc.shtml) |
| 月 | CPC 官方 RONI 概率与分位展望 | 每月第二个周四 | [RONI Outlook](https://www.cpc.ncep.noaa.gov/products/analysis_monitoring/enso/roni/outlook/) |
| 月 | IRI/CPC 多模式 plume（22 个模式） | 每月约 19 日 | [IRI ENSO Forecast](https://iri.columbia.edu/our-expertise/climate/forecasts/enso/current/) |
| 月 | JMA エルニーニョ監視速報 | 每月约 10 日 | [JMA](https://www.data.jma.go.jp/cpd/elnino/index.html) |
| 半月 | BoM ENSO Wrap-Up（含每日 SOI） | 每两周（周二） | [bom.gov.au/climate/enso](http://www.bom.gov.au/climate/enso/) |
| 月 | 国家气候中心（中国业务口径） | 月度 | [cmdp.ncc-cma.net](https://cmdp.ncc-cma.net/pred/cn_enso.php?product=cn_enso_bj) |
| 月 | NOAA PSL 指数库（ONI/RONI/MEI/SOI…） | 月度 | [PSL Monthly Indices](https://psl.noaa.gov/data/timeseries/month/) |
| 季节 | CPC 全球 ENSO 温度/降水线性回归（地图底图） | 静态（按季节） | [Global ENSO Regressions](https://www.cpc.ncep.noaa.gov/products/precip/CWlink/ENSO/regressions/) |

## 口径提醒（重要）

- **ONI**：ERSSTv5，1971–2000 基准，**含**全球增暖趋势。
- **RONI**：ERSSTv6，1991–2020 基准，已扣除 20°N–20°S 热带平均增暖，是 **CPC 现行官方验证指标**。
- **周 Niño3.4**：OISST v2.1 周平均，报告中同时给出"绝对距平"和"相对距平"两列。
- 三者数值不可混用、不可互相比较；阈值判定与趋势分析请全程固定同一套指数。
- ENSO 官方指数**不存在日频标准产品**，周频已是最高时效。

## 影响区地图的说明与边界

- 图中的色块是**倾向性示意**（偏多雨 / 偏干旱 / 偏暖 / 偏凉），来自历史 El Niño 事件的合成与线性回归（CPC 全球回归、Ropelewski & Halpert 1987/1996 等），表示**发生概率的相对偏移**，不是确定性预报。
- 影响会随事件强度、空间型（东部型 / 中部型）与年代际背景改变；把握度用 ●●●/●●○/●○○ 标注，仅为定性参考。
- 底图为 Natural Earth 110m 简化陆地轮廓，等经纬度投影、太平洋居中；色块为示意范围，非精确边界。
- 官方权威图版请以下方内嵌的 CPC 全球回归图和国家气候中心/本地气象部门结论为准。

## 部署到 GitHub Pages

**线上地址：<https://pengzhenran.github.io/enso-dashboard/>**（仓库 <https://github.com/pengzhenran/enso-dashboard>，Pages 源为 `main` 分支的 `/docs` 目录）

页面是**零外部请求的单文件**，非常适合静态托管。

### 日常更新：一条命令

```powershell
# 重新抓数 → 生成 docs/index.html → 通过 GitHub API 发布
powershell -ExecutionPolicy Bypass -File .\scripts\Publish-ToGitHub.ps1

# 只重传现有页面，不重新抓数
powershell -ExecutionPolicy Bypass -File .\scripts\Publish-ToGitHub.ps1 -SkipRegenerate -Path docs/index.html
```

`Publish-ToGitHub.ps1` 用 **GitHub Git Data API**（blob → tree → commit → 更新分支）发布，等价于一次 `git push`，但只需要 `api.github.com` 可达。**很多国内网络 git push 到 github.com 会被 reset，而 api.github.com 通常能通**，所以本仓库推荐用这个脚本而不是 `git push`。

### 可选：让 GitHub Actions 每周自动更新

仓库里已备好 `.github/workflows/enso-pages.yml`（每周一 UTC 02:00 在 `windows-latest` 上重新抓数、自检、发布）。但它**没有随代码上传**，因为当前 `gh` token 缺少 `workflow` 权限（GitHub 对 `.github/workflows/*` 一律拒绝写入）。启用步骤：

```powershell
gh auth refresh -s workflow                # 一次性授权，浏览器里确认
powershell -ExecutionPolicy Bypass -File .\scripts\Publish-ToGitHub.ps1 -SkipRegenerate
```

然后把仓库 **Settings → Pages → Build and deployment → Source** 改成 **GitHub Actions**；也可以在网页端 **Add file → Create new file**，路径填 `.github/workflows/enso-pages.yml`，粘贴本地同名文件的内容（无需改 token 权限）。

### 说明与注意

- **公开性**：公开仓库的 Pages 站点对所有人可见；私有仓库要用 Pages 需要 GitHub Pro/Team。不想公开可改用 Cloudflare Pages、Vercel，或只把 `docs/index.html` 当附件分发。
- 页面运行时**不抓任何数据**，不存在 CORS/接口失效问题；数据新鲜度取决于上一次发布时间（页头会显示生成时间）。
- 单文件（`docs/index.html`）不到 0.5 MB，远低于 Pages 限制；`data/raw/` 已通过 `.gitignore` 排除。
- 本地 `git` 的 `origin` 仍指向 https 地址，但该网络下推不上去；请用 `Publish-ToGitHub.ps1`。

## 部署到微信

本仓库只产出**网页版**，所以微信侧的唯一路线是**公众号菜单挂链接**（或用「阅读原文」）：
需要一个**国内可访问的 HTTPS 地址**，并且账号有菜单权限。

### ⚠️ 现有 Pages 地址在国内打不开

GitHub Pages 本身是好的（`status: built`、公开、HTTPS），但实测
**`https://pengzhenran.github.io/enso-dashboard/` 从国内 8 秒超时**（同一时刻 baidu.com 139 ms 返回 200）。
DNS 能解析到 GitHub 真实 IP，但连接被阻断。

所以挂到公众号之前必须先换托管（推荐 [EdgeOne Pages Drop](https://pages.edgeone.ai/zh/drop)，
免费、拖放部署、腾讯云 CDN），详见 [WECHAT.md](WECHAT.md)。

### 公众号菜单的一个硬性限制

官方[创建自定义菜单](https://developers.weixin.qq.com/doc/subscription/api/custommenu/api_createcustommenu)
文档的「适用范围」写明：`/cgi-bin/menu/create` 对**订阅号是「仅认证」**——
只允许**企业主体已认证**账号调用。个人主体永远无法通过认证达到这个门槛，
所以[菜单脚本](scripts/Configure-WeChatMenu.ps1)只对企业认证主体或服务号可用；
未认证账号只能用后台可视化菜单（如果后台有这个入口的话）。

## 每天自动更新（本机计划任务）

`scripts/Auto-Update-Web.ps1` 把三件事串成一条链，供计划任务直接调用：

```
抓 CPC 数据 → 重建 report\ 与 docs\ → 自检 35 项 × 2 份 → 走 API 推送到 main
```

**自检不过就绝不发布**；数据与页面都没变就跳过；每步都写日志到 `data\logs\auto-update-YYYY-MM.log`。

```powershell
# 手动跑一次（联网抓数 → 生成 → 自检 → 发布）
powershell -ExecutionPolicy Bypass -File .\scripts\Auto-Update-Web.ps1

# 只改了模板、不联网
powershell -ExecutionPolicy Bypass -File .\scripts\Auto-Update-Web.ps1 -NoDownload

# 只看结果、先不发布
powershell -ExecutionPolicy Bypass -File .\scripts\Auto-Update-Web.ps1 -SkipPublish
```

已注册的计划任务（每天 09:30，任务名 `EnsoDashboard`）：

```powershell
schtasks /Create /TN "EnsoDashboard" /SC DAILY /ST 09:30 ^
  /TR "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File \"D:\华为家庭存储\mywork\enso\scripts\Auto-Update-Web.ps1\"" /F

schtasks /Query /TN "EnsoDashboard"     # 查看（Last Result 应为 0）
schtasks /Run   /TN "EnsoDashboard"     # 立即跑一次
schtasks /Delete /TN "EnsoDashboard" /F # 删除
```

> 计划任务的 PATH 与码页都和交互终端不同，这里踩过两个坑，改动时不要回退：
> 1. **`gh` 靠 PATH 找不到** —— `Publish-ToGitHub.ps1` 会主动把
>    `C:\Program Files\GitHub CLI` 补进 PATH，并用绝对路径调用。
> 2. **中文提交信息被解成乱码** —— 任务环境是 OEM/GBK 码页，`gh` 输出 UTF-8，
>    直接接管道后 `ConvertFrom-Json` 会报「传入的对象无效」。现在改为把 `gh` 输出
>    重定向到文件、再显式按 UTF-8 读回，与运行环境无关。
>
> 另外：本机还有一个旧任务 `\ENSO-DataWatch`（指向 `D:\myds\mywork\enso`、
> 从未成功运行过），与本仓库无关，可自行删除以免混淆。
>
> 想彻底摆脱本机、改成云端每周自动跑，见 `.github/workflows/enso-pages.yml`
> （需先 `gh auth refresh -s workflow` 授权后才能真正上传）。

## 维护备注

- 源码中的正则依赖 CPC 的固定文本格式与页面表格 `id`（`wksst9120.for` 的"负距平与 SST 连写"、`oni/RONI/Rnino34.ascii.txt`、`soi`、`id="probabilities-table"`、`id="outlook-table"`）。CPC 改版后若某项为空，先看 `data/raw/` 里的原始文件是否变格式。
- 网页版改样式只动 `scripts/dashboard.template.html`，不要往 `Update-EnsoData.ps1` 里塞 HTML；模板里含 `${...}` 模板字面量，**必须用单引号 here-string 或 `File::ReadAllText` 读入**，否则 PowerShell 会展开变量。
- `Update-EnsoData.ps1` 含中文，**必须保存为 UTF-8 with BOM**，否则 Windows PowerShell 5.1 会按 GBK 解析而报语法错。用编辑器直接改这个文件时注意别把 BOM 丢掉（丢了就报 `Unexpected token`）。
- `scripts/verify-report.mjs` 会在 Node 里用 DOM/Canvas 桩真实执行页面脚本，并模拟滚轮缩放、拖动平移、单击定位、双击复位，可当作改动后的回归测试。桩环境没有 `requestAnimationFrame` / `IntersectionObserver`，正好用来验证"动画关闭时页面照样完整渲染"这条降级路径。
- 三个 CPC 动态页面（诊断 / 展望 / 概率）的 HTTP `Last-Modified` 等于请求时刻，没有参考价值，报告里改显示解析出的"内容日期"。
- 数据版权归各来源机构；本页仅供监测参考，不构成预报结论。
