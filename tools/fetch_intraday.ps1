<#
  fetch_intraday.ps1 — 抓取新浪期货"分时线"（1 分钟），供站点"日内"图使用。

  数据源：https://stock2.finance.sina.com.cn/futures/api/jsonp.php/var%20t=/InnerFuturesNewService.getMinLine?symbol=AU0
  返回：var t=([["21:00","780.320","780.285","1339","148704","780.800","2026-11-24"],["21:01",...],...])
        每行 [时间, 最新价, 均价, 成交量, 持仓?, 昨结, 交易日(仅首行)]

  输出：data/intraday.json
  {
    generatedAt, tradeDate,
    series: { "<seriesId>": { symbol, name, unit, date, prevClose, points: [["YYYY-MM-DD HH:MM", price], ...] } }
  }

  说明：分时数据是"期货主力连续"，与站内上金所 Au99.99 等现货序列口径不同，
        前端必须单独标注来源与合约，不与现货序列混画（PRD 铁律）。
#>
param(
  [switch]$DryRun,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dataDir = Join-Path $root 'data'
$outDir = Join-Path $dataDir 'intraday'
$idxPath = Join-Path $outDir 'index.json'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36'

function Say($msg) { if (-not $Quiet) { Write-Host $msg } }

function Write-TextNoBom($path, $text) {
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# seriesId 必须与 data/series.json 中的 id 一致
$MAP = @(
  @{ id = 'au-sge-9999';                  sym = 'AU0'; name = '沪金主力连续'; unit = '元/克' },
  @{ id = 'ag-sge-td';                    sym = 'AG0'; name = '沪银主力连续'; unit = '元/千克' },
  @{ id = 'cu-shfe-cathode';              sym = 'CU0'; name = '沪铜主力连续'; unit = '元/吨' },
  @{ id = 'al-shfe-a00';                  sym = 'AL0'; name = '沪铝主力连续'; unit = '元/吨' },
  @{ id = 'pb-shfe-1';                    sym = 'PB0'; name = '沪铅主力连续'; unit = '元/吨' },
  @{ id = 'zn-shfe-0';                    sym = 'ZN0'; name = '沪锌主力连续'; unit = '元/吨' },
  @{ id = 'ni-shfe-1';                    sym = 'NI0'; name = '沪镍主力连续'; unit = '元/吨' },
  @{ id = 'sn-shfe-1';                    sym = 'SN0'; name = '沪锡主力连续'; unit = '元/吨' },
  @{ id = 'intl-copper-sina-main';        sym = 'BC0'; name = '国际铜主力连续'; unit = '元/吨' },
  @{ id = 'iron-ore-sina-main';           sym = 'I0';  name = '铁矿石主力连续'; unit = '元/吨' },
  @{ id = 'lithium-carbonate-sina-main';  sym = 'LC0'; name = '碳酸锂主力连续'; unit = '元/吨' },
  @{ id = 'industrial-silicon-sina-main'; sym = 'SI0'; name = '工业硅主力连续'; unit = '元/吨' },
  @{ id = 'polysilicon-sina-main';        sym = 'PS0'; name = '多晶硅主力连续'; unit = '元/吨' },
  @{ id = 'alumina-sina-main';            sym = 'AO0'; name = '氧化铝主力连续'; unit = '元/吨' },
  @{ id = 'ferrosilicon-sina-main';       sym = 'SF0'; name = '硅铁主力连续'; unit = '元/吨' },
  @{ id = 'mn-si-sina-main';              sym = 'SM0'; name = '锰硅主力连续'; unit = '元/吨' }
)

function Get-WebText($url) {
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    $args = @('-s', '--compressed', '-A', $ua, '-e', 'https://finance.sina.com.cn/', '--max-time', '20', '-o', $tmp, $url)
    & curl.exe @args 2>$null | Out-Null
    if (-not (Test-Path $tmp)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($tmp)
    if ($bytes.Length -lt 32) { return $null }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
  } finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
  }
}

function Get-MinuteLine($sym) {
  $url = 'https://stock2.finance.sina.com.cn/futures/api/jsonp.php/var%20t=/InnerFuturesNewService.getMinLine?symbol=' + $sym
  $text = Get-WebText $url
  if (-not $text) { return $null }
  if ($text -match '__ERROR') { return $null }

  $start = $text.IndexOf('([')
  if ($start -lt 0) { $start = $text.IndexOf('(') }
  $end = $text.LastIndexOf(')')
  if ($start -lt 0 -or $end -le $start) { return $null }
  $json = $text.Substring($start + 1, $end - $start - 1).Trim()
  # ( [...] ) -> [...]
  if ($json.StartsWith('(') -and $json.EndsWith(')')) {
    $json = $json.Substring(1, $json.Length - 2).Trim()
  }
  $rows = $null
  try { $rows = $json | ConvertFrom-Json } catch { return $null }
  if (-not $rows -or @($rows).Count -lt 2) { return $null }

  $tradeDate = $null
  $prevClose = $null
  $points = New-Object System.Collections.ArrayList

  foreach ($r in @($rows)) {
    $cells = @($r)
    if ($cells.Count -lt 2) { continue }
    $hm = [string]$cells[0]
    if ($hm -notmatch '^\d{1,2}:\d{2}$') { continue }
    $price = 0.0
    if (-not [double]::TryParse([string]$cells[1], [ref]$price)) { continue }
    if ($price -le 0) { continue }

    if ($cells.Count -ge 7 -and -not $tradeDate) {
      $d = [string]$cells[6]
      if ($d -match '^\d{4}-\d{2}-\d{2}$') { $tradeDate = $d }
      $pc = 0.0
      if ([double]::TryParse([string]$cells[5], [ref]$pc) -and $pc -gt 0) { $prevClose = $pc }
    }

    # 夜盘 20:00 之后的点属于交易日前一自然日
    $day = $tradeDate
    if ($hm -ge '20:00') {
      $day = ([datetime]::ParseExact($tradeDate, 'yyyy-MM-dd', $null)).AddDays(-1).ToString('yyyy-MM-dd')
    }
    [void]$points.Add(@("$day $hm", [math]::Round($price, 3)))
  }

  if (-not $tradeDate) { $tradeDate = (Get-Date).ToString('yyyy-MM-dd') }
  if ($points.Count -lt 30) { return $null }

  return @{ tradeDate = $tradeDate; prevClose = $prevClose; points = $points }
}

$series = [ordered]@{}
$ok = 0
$fail = @()
$tradeDate = $null

foreach ($m in $MAP) {
  $res = $null
  try { $res = Get-MinuteLine $m.sym } catch { $res = $null }
  if (-not $res) { $fail += ($m.sym + '(' + $m.id + ')'); Say ('  [失败] ' + $m.sym); continue }

  if (-not $tradeDate) { $tradeDate = $res.tradeDate }
  $series[$m.id] = [ordered]@{
    symbol    = $m.sym
    name      = $m.name
    unit      = $m.unit
    date      = $res.tradeDate
    prevClose = $res.prevClose
    points    = @($res.points)
  }
  $ok++
  Say ('  [分时] ' + $m.sym + ' ' + $m.name + ' ' + $res.points.Count + ' 点 交易日 ' + $res.tradeDate)
  Start-Sleep -Milliseconds 120
}

if ($ok -eq 0) {
  Say '分时数据全部抓取失败，未写文件。'
  exit 3
}

function Convert-ToJsonNoEsc($obj, $depth) {
  $j = ConvertTo-Json -InputObject $obj -Depth $depth -Compress:$false
  return [regex]::Replace($j, '\\u([0-9a-fA-F]{4})', {
    param($m)
    [char][Convert]::ToInt32($m.Groups[1].Value, 16)
  })
}

Say ("分时序列 " + $ok + " 条，交易日 " + $tradeDate)
if ($fail.Count) { Say ('  失败：' + ($fail -join ', ')) }

# 按品种拆分文件，前端点开「日内」时才加载对应那一个（整包 1.7 MB 太重）
$index = [ordered]@{
  generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
  tradeDate   = $tradeDate
  count       = $ok
  note        = '分时数据为新浪期货「主力合约连续」，与站内现货/交易所日线口径不同，仅用于日内走势参考。'
  series      = [ordered]@{}
}
$totalKB = 0

foreach ($k in $series.Keys) {
  $one = $series[$k]
  $full = [ordered]@{
    id          = $k
    symbol      = $one.symbol
    name        = $one.name
    unit        = $one.unit
    date        = $one.date
    prevClose   = $one.prevClose
    generatedAt = $index.generatedAt
    points      = $one.points
  }
  $json = Convert-ToJsonNoEsc $full 6
  $kb = [math]::Round($json.Length / 1024, 1)
  $totalKB += $kb
  if (-not $DryRun) {
    Write-TextNoBom (Join-Path $outDir ($k + '.json')) $json
  }
  $index.series[$k] = [ordered]@{
    file      = $k + '.json'
    symbol    = $one.symbol
    name      = $one.name
    unit      = $one.unit
    date      = $one.date
    prevClose = $one.prevClose
    count     = @($one.points).Count
    kb        = $kb
  }
}

$idxJson = Convert-ToJsonNoEsc $index 6
if ($DryRun) {
  Say ('（DryRun：未写盘）目录 ' + $outDir + '  合计约 ' + [math]::Round($totalKB, 1) + ' KB，索引 ' + [math]::Round($idxJson.Length / 1024, 1) + ' KB')
  exit 0
}
Write-TextNoBom $idxPath $idxJson
Say ('已写入 ' + $outDir + '  共 ' + $ok + ' 个文件 / ' + [math]::Round($totalKB, 1) + ' KB，索引 ' + [math]::Round($idxJson.Length / 1024, 1) + ' KB')
