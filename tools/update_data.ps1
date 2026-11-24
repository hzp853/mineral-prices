# =============================================================================
#  update_data.ps1 —— 抓取公开行情并更新 site/data 下的数据文件
#
#  用法（Windows PowerShell 5.1 与 pwsh 7 均可）：
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\update_data.ps1
#    powershell ... -Days 5          # 只补最近 5 个交易日
#    powershell ... -Backfill 250    # 首次回填 250 个交易日
#    powershell ... -Backfill 250 -Force   # 丢掉现有数据整体重抓
#    powershell ... -DryRun          # 只打印，不写文件
#    powershell ... -NoCache         # 不走本地缓存
#
#  能自动更新的（交易所公开数据，可信度 A）：
#    上期所 沪铜/沪铝/沪铅/沪锌/沪镍/沪锡 主力合约收盘价
#    上金所 Au99.99、Ag(T+D) 收盘价
#  其余品种没有免费公开接口，用 tools\manual_quotes.csv 手工补数。
# =============================================================================
param(
  [int]$Days = 0,
  [int]$Backfill = 250,
  [switch]$DryRun,
  [switch]$Quiet,
  [switch]$NoCache,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'

$Root     = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$DataDir  = Join-Path $Root 'data'
$SeriesP  = Join-Path $DataDir 'series.json'
$CatalogP = Join-Path $DataDir 'catalog.json'
$MetaP    = Join-Path $DataDir 'meta.json'
$SourcesP = Join-Path $DataDir 'sources.json'
$VarietyP = Join-Path $DataDir 'varieties.json'
$BundleP  = Join-Path $DataDir 'bundle.js'
$ManualP  = Join-Path $Root 'tools\manual_quotes.csv'
$LogP     = Join-Path $DataDir 'update-log.json'
$CacheDir = Join-Path $Root 'tools\.cache'
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }

$UA = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36' }

function Say($msg) { if (-not $Quiet) { Write-Host $msg } }

# ---------------------------------------------------------------- 读写工具
function Read-Json($path) {
  $txt = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  return $txt | ConvertFrom-Json
}

# PS 5.1 的 ConvertFrom-Json 以 -NoEnumerate 输出数组，@() 包一层只会得到 1 个元素，
# 所以统一走这个函数：把数组逐项输出，调用方再 @() 就是真正的 N 个元素。
function Read-JsonArray($path) {
  $o = Read-Json $path
  if ($null -eq $o) { return }
  if ($o -is [System.Array]) { foreach ($x in $o) { $x } return }
  return $o
}

function Write-TextNoBom($path, $text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $text, $enc)
}

# PS 5.1 的 ConvertTo-Json 把中文转成 \uXXXX，这里还原；
# 必须用 -InputObject，走管道会把数组包成 {"value":[...],"Count":n}
function Write-Json($path, $obj, [int]$depth = 8) {
  $json = ConvertTo-Json -InputObject $obj -Depth $depth
  $json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', {
    param($m); [char][Convert]::ToInt32($m.Groups[1].Value, 16)
  })
  Write-TextNoBom $path $json
}

function Get-Price($v) {
  if ($null -eq $v) { return $null }
  $d = 0.0
  if ([double]::TryParse([string]$v, [ref]$d)) { return $d }
  return $null
}

function Get-DateStr($d) { return $d.ToString('yyyy-MM-dd') }

# ---------------------------------------------------------------- 抓取上期所
# 每日文件：https://www.shfe.com.cn/data/tradedata/future/dailydata/kxYYYYMMDD.dat
# o_curinstrument[] 每行一个合约：PRODUCTID(如 cu_f)、DELIVERYMONTH、CLOSEPRICE、OPENINTEREST
function Get-ShfeDay([datetime]$d) {
  $stamp = $d.ToString('yyyyMMdd')
  $cacheFile = Join-Path $CacheDir ('kx' + $stamp + '.json')
  $txt = $null
  if (-not $NoCache -and (Test-Path $cacheFile)) {
    try { $txt = [System.IO.File]::ReadAllText($cacheFile, [System.Text.Encoding]::UTF8) } catch { $txt = $null }
  }
  if (-not $txt) {
    $url = 'https://www.shfe.com.cn/data/tradedata/future/dailydata/kx' + $stamp + '.dat'
    try {
      $r = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers $UA -TimeoutSec 25
    } catch {
      return $null            # 404 = 非交易日
    }
    $txt = $r.Content
    if ($txt -notmatch 'o_curinstrument') { return $null }
    if (-not $NoCache) { try { Write-TextNoBom $cacheFile $txt } catch {} }
  }
  if ($txt -notmatch 'o_curinstrument') { return $null }
  try { $j = $txt | ConvertFrom-Json } catch { return $null }
  if (-not $j.o_curinstrument) { return $null }

  $out = @{}
  foreach ($row in $j.o_curinstrument) {
    $prodId = [string]$row.PRODUCTID
    if (-not $prodId) { continue }
    $code = ($prodId -split '_')[0]        # cu_f -> cu
    $close = Get-Price $row.CLOSEPRICE
    if ($null -eq $close -or $close -le 0) { continue }
    $oi = Get-Price $row.OPENINTEREST
    if ($null -eq $oi) { $oi = 0 }
    if (-not $out.ContainsKey($code)) { $out[$code] = @() }
    $out[$code] += , @{ close = $close; oi = $oi; month = [string]$row.DELIVERYMONTH }
  }
  return $out
}

# 抓取最近 N 个交易日（所有品种共用，一天只请求一次），返回按日期升序的数组
function Get-ShfeWindow($limit) {
  $rev = @()
  $d = $today
  $iter = 0
  $stopAt = $today.AddDays(-([math]::Ceiling([double]$limit * 2.5) + 15))
  while ($rev.Count -lt $limit -and $iter -lt 900 -and $d -ge $stopAt) {
    $iter = $iter + 1
    if ($d.DayOfWeek -ne 'Saturday' -and $d.DayOfWeek -ne 'Sunday') {
      $day = $null
      try { $day = Get-ShfeDay $d } catch { $day = $null }
      if ($day) { $rev += @{ d = (Get-DateStr $d); map = $day } }
    }
    $d = $d.AddDays(-1)
  }
  [array]::Reverse($rev)
  return $rev
}

# 主力合约：持仓量最大者为候选；若原主力仍在（持仓不低于新候选的 60%）就不换月，
# 避免持仓量来回交叉导致价格序列出现无意义的跳空。
function Select-MainContract($contracts, $prevMonth) {
  if (-not $contracts -or $contracts.Count -eq 0) { return $null }
  $best = $contracts[0]
  foreach ($c in $contracts) { if ($c.oi -gt $best.oi) { $best = $c } }
  if ($prevMonth) {
    foreach ($c in $contracts) {
      if ($c.month -eq $prevMonth -and $c.oi -ge $best.oi * 0.6) { return $c }
    }
  }
  return $best
}

# ---------------------------------------------------------------- 抓取上金所
# https://www.sge.com.cn/graph/Dailyhq?instid=Au99.99
# time[] 每行：[日期, 开盘, 收盘, 最低, 最高]
function Get-SgeSeries($instid) {
  $url = 'https://www.sge.com.cn/graph/Dailyhq?instid=' + [System.Uri]::EscapeDataString($instid)
  $r = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers $UA -TimeoutSec 30
  $j = $r.Content | ConvertFrom-Json
  $rows = @()
  foreach ($row in $j.time) {
    if (-not $row -or $row.Count -lt 3) { continue }
    $close = Get-Price $row[2]
    if ($null -eq $close -or $close -le 0) { continue }
    $rows += , @([string]$row[0], $close)
  }
  return $rows
}

# ---------------------------------------------------------------- 新鲜度
function Get-Freshness($freq, $asOf) {
  if (-not $asOf) { return 'stopped' }
  $d = [datetime]::ParseExact($asOf, 'yyyy-MM-dd', $null)
  $ref = (Get-Date).Date
  if ($ref.DayOfWeek -eq 'Saturday') { $ref = $ref.AddDays(-1) }
  if ($ref.DayOfWeek -eq 'Sunday') { $ref = $ref.AddDays(-2) }
  $days = ($ref - $d).Days
  if ($freq -eq 'weekly') {
    if ($days -le 7) { return 'normal' }
    if ($days -le 21) { return 'stale' }
    return 'stopped'
  }
  if ($freq -eq 'monthly') {
    if ($days -le 31) { return 'normal' }
    if ($days -le 62) { return 'stale' }
    return 'stopped'
  }
  if ($days -le 2) { return 'normal' }
  if ($days -le 5) { return 'stale' }
  return 'stopped'
}

# ================================================================ 序列映射
$MAP = @(
  @{ sid = 'cu-shfe-cathode'; kind = 'shfe'; code = 'cu'; label = '上期所 · 沪铜主力 · 收盘价'; unit = '元/吨'; grade = '主力连续合约' },
  @{ sid = 'al-shfe-a00';     kind = 'shfe'; code = 'al'; label = '上期所 · 沪铝主力 · 收盘价'; unit = '元/吨'; grade = '主力连续合约' },
  @{ sid = 'pb-shfe-1';       kind = 'shfe'; code = 'pb'; label = '上期所 · 沪铅主力 · 收盘价'; unit = '元/吨'; grade = '主力连续合约' },
  @{ sid = 'zn-shfe-0';       kind = 'shfe'; code = 'zn'; label = '上期所 · 沪锌主力 · 收盘价'; unit = '元/吨'; grade = '主力连续合约' },
  @{ sid = 'ni-shfe-1';       kind = 'shfe'; code = 'ni'; label = '上期所 · 沪镍主力 · 收盘价'; unit = '元/吨'; grade = '主力连续合约' },
  @{ sid = 'sn-shfe-1';       kind = 'shfe'; code = 'sn'; label = '上期所 · 沪锡主力 · 收盘价'; unit = '元/吨'; grade = '主力连续合约' },
  @{ sid = 'au-sge-9999';     kind = 'sge';  code = 'Au99.99'; label = '上金所 · Au99.99 · 收盘价'; unit = '元/克'; grade = 'Au99.99' },
  @{ sid = 'ag-sge-td';       kind = 'sge';  code = 'Ag(T+D)'; label = '上金所 · Ag(T+D) · 收盘价'; unit = '元/千克'; grade = 'Ag(T+D)' }
)

# ================================================================ 主流程
Say '=== 矿产品价格中枢 · 数据更新 ==='

if (-not (Test-Path $SeriesP)) { throw "找不到 $SeriesP" }
$series    = @(Read-JsonArray $SeriesP)
$catalog   = @(Read-JsonArray $CatalogP)
$meta      = Read-Json $MetaP
$varieties = @(Read-JsonArray $VarietyP)

$seriesByI = @{}
$varietyByI = @{}
foreach ($s in $series) {
  if (-not ($s.PSObject.Properties.Name -contains 'demo')) {
    $s | Add-Member -NotePropertyName demo -NotePropertyValue $true -Force
  }
  $seriesByI[$s.id] = $s
}
foreach ($v in $varieties) { $varietyByI[$v.id] = $v }

$today = (Get-Date).Date
$report = @()

# ------------------------------------------------ 1) 交易所数据
$limit = $Backfill
if ($Days -gt 0) { $limit = $Days }
$shfeDays = $null

foreach ($m in $MAP) {
  $s = $seriesByI[$m.sid]
  if (-not $s) { Say ('  ! 跳过（无此序列）：' + $m.sid); continue }

  $existing = @($s.points)
  $lastReal = $null
  if ($Force) { $existing = @() } elseif ($s.demo -eq $false -and $existing.Count -gt 0) {
    $lastReal = [datetime]::ParseExact([string]$existing[$existing.Count - 1][0], 'yyyy-MM-dd', $null)
  }

  $newPoints = @()

  if ($m.kind -eq 'sge') {
    $rows = @()
    try { $rows = @(Get-SgeSeries $m.code) } catch { Say ('  ! ' + $m.sid + ' 抓取失败：' + $_.Exception.Message) }
    foreach ($r in $rows) {
      $dt = [datetime]::ParseExact([string]$r[0], 'yyyy-MM-dd', $null)
      if ($lastReal -and $dt -le $lastReal) { continue }
      if ($Days -gt 0 -and $dt -lt $today.AddDays(-$Days * 2)) { continue }
      $newPoints += , @([string]$r[0], [double]$r[1])
    }
  } else {
    if ($null -eq $shfeDays) { $shfeDays = @(Get-ShfeWindow $limit) }
    $prevMonth = $null
    foreach ($it in $shfeDays) {
      $cs = $it.map[$m.code]
      if (-not $cs) { continue }
      $pick = Select-MainContract $cs $prevMonth
      if (-not $pick) { continue }
      if ($lastReal -and [datetime]::ParseExact([string]$it.d, 'yyyy-MM-dd', $null) -le $lastReal) { continue }
      $prevMonth = $pick.month
      $newPoints += , @([string]$it.d, [double]$pick.close)
    }
  }

  if ($newPoints.Count -eq 0) {
    Say ('  - ' + $m.sid + '：无新增（已是最新）')
    $report += [pscustomobject]@{ seriesId = $m.sid; added = 0; status = 'noop' }
    continue
  }

  # 合并 + 升序 + 去重
  $merged = @()
  if ($s.demo -ne $true) { foreach ($p in $existing) { $merged += , @([string]$p[0], [double]$p[1]) } }
  $merged += $newPoints
  $sorted = @($merged | Sort-Object { $_[0] })
  $seen = @{}
  $final = @()
  foreach ($p in $sorted) {
    if ($seen.ContainsKey($p[0])) { continue }
    $seen[$p[0]] = 1
    $final += , @([string]$p[0], [double]$p[1])
  }

  if (-not $DryRun) {
    $s.points = $final
    $s.demo = $false
    $s.label = $m.label
    $s.unit = $m.unit
    $s.freq = 'daily'
    $s.updatedAt = [string]$final[$final.Count - 1][0]
    if ($s.spec) { $s.spec.grade = $m.grade; $s.spec.tax = '含税'; $s.spec.region = '上海' }
  }
  Say ('  + ' + $m.sid + '：新增 ' + $newPoints.Count + ' 条，最新 ' + [string]$final[$final.Count - 1][0] + ' = ' + [string]$final[$final.Count - 1][1])
  $report += [pscustomobject]@{ seriesId = $m.sid; added = $newPoints.Count; status = 'ok' }
}

# ------------------------------------------------ 2) 手工补数
if (Test-Path $ManualP) {
  $added = 0
  foreach ($ln in [System.IO.File]::ReadAllLines($ManualP, [System.Text.Encoding]::UTF8)) {
    if (-not $ln -or $ln.StartsWith('#')) { continue }
    if ($ln -match '^seriesId') { continue }
    $cells = $ln -split ','
    if ($cells.Count -lt 3) { continue }
    $sid = $cells[0].Trim(); $ds = $cells[1].Trim(); $vv = $cells[2].Trim()
    if (-not $sid -or $ds -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
    $val = Get-Price $vv
    if ($null -eq $val) { continue }
    $s = $seriesByI[$sid]
    if (-not $s) { Say ('  ! manual: 未知序列 ' + $sid); continue }
    $pts = @()
    foreach ($p in @($s.points)) { if ($p[0] -ne $ds) { $pts += , @([string]$p[0], [double]$p[1]) } }
    $pts += , @($ds, [double]$val)
    $pts = @($pts | Sort-Object { $_[0] })
    if (-not $DryRun) {
      $s.points = $pts
      $s.demo = $false
      $s.updatedAt = $ds
    }
    $added = $added + 1
  }
  if ($added -gt 0) { Say ('  + manual_quotes.csv：合并 ' + $added + ' 条') }
}

# ------------------------------------------------ 3) 重算 catalog
$srcByI = @{}
foreach ($x in @(Read-JsonArray $SourcesP)) { $srcByI[$x.id] = $x }

$newCatalog = @()
foreach ($s in $series) {
  $pts = @($s.points)
  $v = $varietyByI[$s.varietyId]
  $src = $srcByI[$s.sourceId]
  $latest = $null; $prev = $null; $change = $null; $pct = $null; $asOf = ''
  $spark = @()
  if ($pts.Count -gt 0) {
    $asOf = [string]$pts[$pts.Count - 1][0]
    $latest = [double]$pts[$pts.Count - 1][1]
    if ($pts.Count -gt 1) { $prev = [double]$pts[$pts.Count - 2][1] }
    if ($null -ne $prev -and $prev -ne 0) {
      $change = [math]::Round($latest - $prev, 4)
      $pct = [math]::Round((($latest - $prev) / $prev) * 100, 4)
    }
    $from = [math]::Max(0, $pts.Count - 12)
    for ($i = $from; $i -lt $pts.Count; $i++) { $spark += [double]$pts[$i][1] }
  }
  $newCatalog += [pscustomobject]@{
    seriesId    = $s.id
    varietyId   = $s.varietyId
    varietyName = $(if ($v) { $v.name } else { $s.varietyId })
    category    = $(if ($v) { $v.category } else { '' })
    unit        = $s.unit
    latest      = $latest
    prev        = $prev
    change      = $change
    changePct   = $pct
    asOf        = $asOf
    sourceId    = $s.sourceId
    trust       = $(if ($src) { $src.trust } else { 'D' })
    freshness   = (Get-Freshness $s.freq $asOf)
    demo        = [bool]$s.demo
    spark       = $spark
  }
}

# ------------------------------------------------ 4) 写回文件
if (-not $DryRun) {
  $maxAsOf = ''
  foreach ($c in $newCatalog) { if ($c.asOf -gt $maxAsOf) { $maxAsOf = $c.asOf } }
  $anyDemo = @($series | Where-Object { $_.demo -eq $true }).Count -gt 0

  $meta.dataAsOf = $maxAsOf
  $meta.generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
  $meta.demoData = $anyDemo

  Write-Json $SeriesP @($series)
  Write-Json $CatalogP @($newCatalog)
  Write-Json $MetaP $meta

  $cats = @(Read-JsonArray (Join-Path $DataDir 'categories.json'))
  $sources = @(Read-JsonArray $SourcesP)
  $bundleObj = [pscustomobject]@{
    meta = $meta; categories = $cats; varieties = $varieties
    sources = $sources; series = @($series); catalog = @($newCatalog)
  }
  $bundleJson = ConvertTo-Json -InputObject $bundleObj -Depth 10 -Compress
  $bundleJson = [regex]::Replace($bundleJson, '\\u([0-9a-fA-F]{4})', {
    param($m); [char][Convert]::ToInt32($m.Groups[1].Value, 16)
  })
  Write-TextNoBom $BundleP ('/* 自动生成：6 个 JSON 的打包备份，供 file:// 直接打开时使用 */' + "`n" + 'window.__MINE_BUNDLE__ = ' + $bundleJson + ';' + "`n")

  $log = [pscustomobject]@{
    ranAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    dataAsOf = $maxAsOf
    demoSeries = @($newCatalog | Where-Object { $_.demo -eq $true } | ForEach-Object { $_.seriesId })
    realSeries = @($newCatalog | Where-Object { $_.demo -ne $true } | ForEach-Object { $_.seriesId })
    steps = $report
  }
  Write-Json $LogP $log
} else {
  Say '（DryRun：未写入任何文件）'
}

Say ''
Say ('=== 完成：catalog ' + $newCatalog.Count + ' 条，真实数据 ' + @($newCatalog | Where-Object { $_.demo -ne $true }).Count + ' 条，示例 ' + @($newCatalog | Where-Object { $_.demo -eq $true }).Count + ' 条 ===')
