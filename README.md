# 矿产品价格中枢 · 站点说明

一个**纯静态**的矿产品（金属 / 非金属）价格看板：双击 `index.html` 即可在本地浏览器打开，
不需要 Node、不需要 Python；也可以托管到 GitHub Pages，让同事在外网用链接打开。

> 需求与规格见上一级目录的 `需求文档.md`（v1.2）。

**当前数据状态**：`catalog.json` 共 23 条序列，其中 **8 条是交易所公开行情（真实）**——
上期所沪铜/沪铝/沪铅/沪锌/沪镍/沪锡主力收盘价、上金所 Au99.99 与 Ag(T+D) 收盘价；
**其余 15 条是程序生成的演示数据**，卡片上有橙色「示例」徽章。

---

## 一、怎么打开

1. 直接双击 `D:\AI工作区\10_矿产品价格网站\site\index.html`；
2. 或用浏览器打开 `file:///D:/AI工作区/10_矿产品价格网站/site/index.html`；
3. 想分享深色版：在地址后面加 `?theme=dark`，例如 `index.html#/variety/cu?theme=dark`。

页面用 hash 路由，所有链接形如 `index.html#/category/nonmetal`、`index.html#/variety/cu?series=cu-smm-gd`，
可以直接复制给别人。

## 二、目录结构

```
site/
├─ index.html              入口（只有骨架，内容由 JS 渲染）
├─ assets/
│  ├─ styles.css           全站样式（浅色/深色、响应式、表格转卡片）
│  ├─ chart.js             手写 SVG 图表：折线、断点虚线、面积渐变、悬停十字光标、迷你走势
│  └─ app.js               数据加载、hash 路由、8 个页面、格式化、自选、CSV 导出
├─ data/                   ← 唯一的数据源，改这里就改全站
│  ├─ meta.json            站点信息、数据截止日、示例数据开关
│  ├─ categories.json      5 个分类
│  ├─ varieties.json       20 个品种
│  ├─ sources.json         8 个数据来源（含可信度 A/B/C/D）
│  ├─ series.json          23 条报价序列（含历史点）
│  ├─ catalog.json         23 条"最新一期"摘要（首页速览/榜单用）
│  ├─ update-log.json      最近一次自动更新的记录（更新时间、真实/示例序列清单）
│  └─ bundle.js            上面 6 个 JSON 的打包备份（file:// 打不开 JSON 时自动回退）
├─ tools/
│  ├─ gen_data.ps1         示例数据生成器（改完口径/品种可重新生成）
│  ├─ update_data.ps1      抓取交易所行情并更新 data/（日常用这个）
│  ├─ install_schedule.ps1 注册/删除 Windows 计划任务（本机每天自动更新）
│  ├─ manual_quotes.csv    手工补数（没有公开接口的品种）
│  └─ .cache/              上期所每日文件的本地缓存（可删，会自动重建）
└─ .github/workflows/
   └─ update.yml           定时任务：每个工作日抓数 → 提交 → 发布到 GitHub Pages
```

## 三、三条铁律（写在代码里，不要破坏）

1. **一条序列 = 一个品种 + 一个口径 + 一个来源。**
   不同口径、不同来源的数据**永远不合并成一条线**，详情页用标签页切换。
   （例：铜有"上期所阴极铜·上海·含税"和"SMM 电解铜·广东·不含税"两条，价格差 9000 元/吨，混在一起就是错的。）
2. **缺失就画断点，不补点、不插值。**
   两期数据间隔超过阈值（日频 >4 天 / 周频 >10 天 / 月频 >45 天）就断开，用虚线连接并注明缺口天数。
   不允许把没有数据的日子画成平线。
3. **每个数字都要能追溯。**
   价格旁边必须有"数据截至 + 来源可信度徽章"，停报/滞后要有明显状态标记。

> 交易所序列（上期所、上金所）例外地不按"缺口"处理：它们的日期本身就是交易日历，
> 周末与法定休市不是数据缺失，详情页会注明"按交易日排列，周末与法定休市不算作缺口"。

## 四、可信度与新鲜度

| 徽章 | 含义 | 本站示例 |
|---|---|---|
| A | 交易所 / 官方 | 上期所、大商所、广期所、上金所 |
| B | 商业数据机构 | SMM、百川盈孚 |
| C | 行业媒体 | 矿权资源网 |
| D | 内部人工录入 | 无（预留） |

新鲜度按频率判定：日频漏更 ≤2 天为「正常」，3–5 天「滞后」，>5 天「停报」；
周频 7/21 天、月频 31/62 天为同样的分界。**「停报」的序列不参与涨跌榜排名**，
首页的涨幅/跌幅前 5 也自动排除。

## 五、每天自动更新数据（update_data.ps1）

```powershell
cd "D:\AI工作区\10_矿产品价格网站\site"
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\update_data.ps1
```

| 参数 | 作用 |
|---|---|
| 无参数 | 抓最近 3 个交易日的增量（日常用法） |
| `-Days 10` | 补最近 10 个交易日 |
| `-Backfill 250` | 首次回填 250 个交易日（约 1 年） |
| `-Force` | 丢掉这些序列现有的点，整段重抓（换数据源时用） |
| `-DryRun` | 只打印结果，不写文件 |
| `-NoCache` | 不使用 `tools/.cache` 的当日文件缓存 |
| `-Quiet` | 少打印 |

脚本会：抓数据 → 合并去重排序 → 重算 `catalog.json`（最新价、涨跌、涨跌幅、新鲜度、迷你走势）
→ 更新 `meta.json` 的数据截止日 → 重写 `bundle.js` 与 `update-log.json`。

**能自动更新的品种（8 条，全部 A 级）**：

- 上期所 6 条：`cu / al / pb / zn / ni / sn` 主力合约收盘价
  来源 `https://www.shfe.com.cn/data/tradedata/future/dailydata/kxYYYYMMDD.dat`
- 上金所 2 条：`Au99.99`、`Ag(T+D)` 收盘价
  来源 `https://www.sge.com.cn/graph/Dailyhq?instid=Au99.99`

"主力合约"的选法：当天持仓量最大的合约，但如果**原来那个合约还在场（持仓 ≥ 新候选的 60%）就不换月**，
避免持仓量来回交叉导致价格序列出现无意义的跳空。

**不能自动更新的品种（15 条）**：大商所铁矿石、广期所碳酸锂、以及钨钼锑镁钴稀土、萤石、磷矿石、石墨等。
这些交易所/机构没有免费的历史接口（大商所与广期所有反爬，SMM 等需付费会员），
只能手工把日报价补进 `tools/manual_quotes.csv`：

```csv
seriesId,date,value
iron-ore-dce,2026-11-20,786
fluorite-kq81-97,2026-11-20,3510
```

补完再跑一次 `update_data.ps1`，脚本会把 CSV 合并进 `series.json` 并把该序列的「示例」标记去掉。
没补之前它们继续显示「示例」徽章，不会被误当成真实行情。

### 让它每天自己跑（本机）

不想手动执行的话，注册一个 Windows 计划任务即可（不需要管理员权限）：

```powershell
cd "D:\AI工作区\10_矿产品价格网站\site"
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\install_schedule.ps1          # 每周一至周五 18:10
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\install_schedule.ps1 -Time 17:30
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\install_schedule.ps1 -Status
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\install_schedule.ps1 -Uninstall
```

本机任务的前提是**电脑开着**；要让同事在外网随时能打开，用下一节的 GitHub Pages 方案（任务跑在 GitHub 的服务器上）。

## 六、发布到公网（GitHub Pages，免费）

1. 在 GitHub 新建一个仓库（如 `mineral-prices`），把 **`site/` 目录里的内容**推到仓库根目录：

   ```powershell
   cd "D:\AI工作区\10_矿产品价格网站\site"
   git init
   git add .
   git commit -m "init: 矿产品价格中枢"
   git branch -M main
   git remote add origin https://github.com/<你的账号>/mineral-prices.git
   git push -u origin main
   ```

2. 仓库 **Settings → Pages → Source** 选 **GitHub Actions**（不要选 Deploy from a branch）。
3. 如果仓库是私有的，确认 **Settings → Actions → General → Workflow permissions** 为
   *Read and write permissions*，否则定时任务无法提交数据。
4. 等第一次 Actions 跑完，页面地址是 `https://<你的账号>.github.io/mineral-prices/`。
5. 定时任务（`.github/workflows/update.yml`）：每周一至周五 **UTC 10:10（北京时间 18:10）**
   自动抓数、提交 `data/`、重新发布；也可以在 Actions 页面点 **Run workflow** 手动触发。

> 不需要服务器、不需要本机开机。数据更新就是一次 commit，Pages 会自动重新部署。
> 想改时间就编辑 `.github/workflows/update.yml` 里的 `cron` 表达式（UTC 时间）。

## 七、怎么换成/新增数据源

站点不关心数据从哪来，只要 `data/` 下的 6 个 JSON 结构不变即可。

- 有新接口：在 `tools/update_data.ps1` 的 `$MAP` 表里加一行（`sid` 序列 id、`kind`、抓取代码、`label`、`unit`、`grade`），
  再写对应的抓取函数。
- 只想手工维护：直接改 `series.json` 的 `points`（`["YYYY-MM-DD", 价格]` 升序、不重复），
  然后把 `catalog.json` 里那条的 `latest / prev / change / changePct / asOf / freshness / spark` 跟着改，
  最后重打 `bundle.js`。更省事的办法是写进 `manual_quotes.csv` 后跑 `update_data.ps1`。
- 想整站换示例数据：改 `tools/gen_data.ps1` 里的配置后重新生成（按序列 id 做确定性伪随机，重复运行结果一致）。

## 八、怎么加品种

1. `varieties.json` 加一条：`id`（英文短横线）、`name`、`aliases`、`category`、`hasFutures`、
   `unit`（元/吨、元/吨度、美元/吨、元/克、元/千克…）、`defaultSeriesId`（默认展示哪条口径）、`description`；
2. `series.json` 加 1~N 条序列，`spec` 里写清 `grade`（品位/牌号）、`tax`（含税/不含税）、
   `region`、`delivery`（出厂/到厂/仓库自提）、`currency`；
3. `catalog.json` 补上对应摘要（或跑一次 `update_data.ps1` 让它自动重算）；
4. 重新打开页面 —— 首页、分类页、口径字典、对比页会自动带上新品种，不需要改前端代码。

## 九、页面一览

| 路由 | 页面 | 说明 |
|---|---|---|
| `#/` | 首页 | 数据说明横幅、概览条、5 张分类卡、20 品种速览表、涨跌前 5 |
| `#/ranking` | 涨跌榜 | 按最新一期涨跌幅排序，可按品种/口径/来源追溯，已剔除停报 |
| `#/category/:id` | 分类页 | 该分类的品种卡片（含迷你走势）+ 全部报价序列表 |
| `#/variety/:id` | 详情页 | 价格卡、口径切换、5 档区间（7/30/90/365/全部）、断点图、区间统计、历史表 + CSV 导出、口径说明、来源可信度、相关品种 |
| `#/compare` | 多品种对比 | 最多 6 个品种，统一归一化到 100 比相对涨跌，可比不同单位的品种 |
| `#/watchlist` | 我的自选 | 星标收藏，存在浏览器 localStorage，不上传 |
| `#/specs` | 口径字典 | 23 条序列的口径全表，回答"这个价格到底是什么价" |
| `#/about` | 关于 | 本站定位、数据说明、免责声明 |

## 十、日内分时（金银铜等 16 条）

详情页在日线图下方会多出一张「日内分时」卡片（只有配了分时数据的序列才有）。

- **数据源**：新浪期货 `InnerFuturesNewService.getMinLine`，返回当个交易日的 1 分钟线（含夜盘 21:00 起）。
- **品种**：沪金 AU0、沪银 AG0、沪铜 CU0、沪铝 AL0、沪铅 PB0、沪锌 ZN0、沪镍 NI0、沪锡 SN0、
  国际铜 BC0、铁矿石 I0、碳酸锂 LC0、工业硅 SI0、多晶硅 PS0、氧化铝 AO0、硅铁 SF0、锰硅 SM0。
- **抓取**：`tools/fetch_intraday.ps1`，写入 `data/intraday/<seriesId>.json` 和 `data/intraday/index.json`。
  按品种拆文件，前端点「加载今日分时」才去取那一个（整包 1.7 MB，不拆会拖慢首屏）。
- **时点**：工作流加了 `20 7 * * 1-5`（15:20 北京，收盘后 20 分钟）专门抓分时；18:10 那次也会再抓一遍。
- **口径提醒（重要）**：分时是**期货主力连续**，与站内上金所 Au99.99 现货、上期所结算价不是同一条口径。
  卡片右上角固定标注「新浪财经（期货主力连续，与上方现货口径不同）」，隔夜/午休按断点画虚线，不连成一条。
  直接打开某品种的日内图可以加参数：`#/variety/au?iv=1`。

## 十一、已知限制

- 静态托管，页面本身没有后端：没有账号、没有服务端预警推送，自选只在本机浏览器里。
- 自动更新覆盖 37 条（交易所 8 + 新浪 8 + 中国有色网 12 + 科矿 3 + Westmetall 6）；萤石/磷矿石走生意社基准价；其余靠 `manual_quotes.csv` 手工补数。
- 分时数据每天只留当日一份（约 500 个点），不做多日留存；要回看某天的日内走势需当天抓过。
- 上金所返回的是**全量历史**（两千多个点），上期所只回溯到 `-Backfill` 指定的长度。
- 图表是手写 SVG，交互限于悬停十字光标 + tooltip，不支持缩放拖拽。
- 移动端已按 375px 验证（无横向滚动、宽表自动转卡片），图表在窄屏刻度精简到 3 个。
- PowerShell 5.1 下写 JSON 有两个坑（已在脚本里规避）：`ConvertFrom-Json` 对数组要逐项展开；
  `ConvertTo-Json` 必须用 `-InputObject`，走管道会把数组包成 `{"value":[…]}`。

## 十二、免责声明

交易所行情来自各交易所公开数据，示例数据由程序生成，**均不构成任何报价或投资建议**。
真实价格以原始来源为准；本站只做展示与对比，不对数据的准确性、完整性、时效性作任何担保。
