<#
  ingest.ps1 —— 多源真实数据装配
  1) 上期所/上金所 8 条官方序列：保留 update_data.ps1 的成果（不重抓）
  2) 新浪期货日线：其余国内期货品种，回补约一年历史
  3) 中国有色网：小金属现货日报（当日）
  4) 科矿网：非金属矿/稀土报价（不定期）

  运行：powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ingest.ps1
        加 -DryRun 只打印不落盘
#>
param(
  [switch]$DryRun,
  [switch]$Quiet,
  [int]$HistoryDays = 380
)

# 在 Linux / .NET Core 上启用 GBK 等代码页（GitHub Actions 的 ubuntu 环境需要）
try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Site = Split-Path -Parent $PSScriptRoot
$DataDir = Join-Path $Site 'data'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'

function Log($msg) { if (-not $Quiet) { Write-Host $msg } }

function Read-JsonArray($path) {
  if (-not (Test-Path $path)) { return @() }
  $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  $obj = $raw | ConvertFrom-Json
  $out = @()
  foreach ($x in $obj) { $out += $x }
  return $out
}

function Write-JsonFile($path, $obj) {
  $json = ConvertTo-Json -InputObject $obj -Depth 12
  $json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', {
    param($m)
    return [string][char][Convert]::ToInt32($m.Groups[1].Value, 16)
  })
  if (-not $DryRun) {
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
  }
}

function Write-TextFile($path, $text) {
  if (-not $DryRun) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
  }
}

function Get-WebText($url, $encoding = 'UTF8', $referer = $null) {
  $headers = @{ 'User-Agent' = $UA }
  if ($referer) { $headers['Referer'] = $referer }
  $r = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 45
  $bytes = $r.RawContentStream.ToArray()
  if ($encoding -eq 'GBK') { return [System.Text.Encoding]::GetEncoding('GBK').GetString($bytes) }
  return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-PlainText($html) {
  $t = $html -replace '(?is)<script.*?</script>', ' '
  $t = $t -replace '(?is)<style.*?</style>', ' '
  $t = $t -replace '(?is)<[^>]+>', ' '
  $t = $t -replace '&nbsp;', ' '
  $t = $t -replace '&amp;', '&'
  return ($t -replace '\s+', ' ').Trim()
}

function Get-DayList($anchor, $days) {
  # anchor: 'YYYY-MM-DD'；返回截至 anchor 的前 days 天日期字符串集合
  $a = [datetime]::ParseExact($anchor, 'yyyy-MM-dd', $null)
  $set = @{}
  for ($i = 0; $i -lt $days; $i++) {
    $set[$a.AddDays(-$i).ToString('yyyy-MM-dd')] = $true
  }
  return $set
}

# ---------------- 品种注册表 ----------------
# mode: official（沿用官方序列）/ sina（新浪期货日线）/ cnmn（有色网）/ kekuang（科矿）
$Varieties = @(
  # 黑色金属
  @{ id='iron-ore';       name='铁矿石';   cat='ferrous';   unit='元/吨';  mode='sina';    sym='I0';   grade='62% 干基'; region='日照港'; desc='进口铁矿石主力合约折算价，元/吨。' }
  @{ id='ferrosilicon';   name='硅铁';     cat='ferrous';   unit='元/吨';  mode='sina';    sym='SF0';  grade='72# 合格块'; region='宁夏'; desc='硅铁期货主力连续收盘价。' }
  @{ id='mn-si';          name='锰硅';     cat='ferrous';   unit='元/吨';  mode='sina';    sym='SM0';  grade='FeMn68Si18'; region='宁夏'; desc='锰硅合金期货主力连续收盘价。' }
  # 有色金属
  @{ id='cu';             name='铜';       cat='nonferrous'; unit='元/吨'; mode='official'; seriesId='cu-shfe-cathode'; desc='上海期货交易所阴极铜主力合约收盘价。' }
  @{ id='al';             name='铝';       cat='nonferrous'; unit='元/吨'; mode='official'; seriesId='al-shfe-a00';     desc='上海期货交易所铝主力合约收盘价。' }
  @{ id='pb';             name='铅';       cat='nonferrous'; unit='元/吨'; mode='official'; seriesId='pb-shfe-1';       desc='上海期货交易所铅主力合约收盘价。' }
  @{ id='zn';             name='锌';       cat='nonferrous'; unit='元/吨'; mode='official'; seriesId='zn-shfe-0';       desc='上海期货交易所锌主力合约收盘价。' }
  @{ id='ni';             name='镍';       cat='nonferrous'; unit='元/吨'; mode='official'; seriesId='ni-shfe-1';       desc='上海期货交易所镍主力合约收盘价。' }
  @{ id='sn';             name='锡';       cat='nonferrous'; unit='元/吨'; mode='official'; seriesId='sn-shfe-1';       desc='上海期货交易所锡主力合约收盘价。' }
  @{ id='alumina';        name='氧化铝';   cat='nonferrous'; unit='元/吨'; mode='sina';    sym='AO0';  grade='AO-1'; region='全国'; desc='氧化铝期货主力连续收盘价。' }
  @{ id='intl-copper';    name='国际铜';   cat='nonferrous'; unit='元/吨'; mode='sina';    sym='BC0';  grade='BC-1'; region='保税区'; desc='国际铜期货主力连续收盘价（不含税）。' }
  @{ id='cobalt';         name='钴';       cat='nonferrous'; unit='元/吨'; mode='cnmn';    match='^钴\('; desc='上海金属现货报价（小金属），钴 99.8% 中间值。' }
  @{ id='antimony';       name='锑';       cat='nonferrous'; unit='元/吨'; mode='cnmn';    match='^锑\(0#';    desc='上海金属现货报价（小金属），锑 0# 中间值。' }
  @{ id='magnesium';      name='镁';       cat='nonferrous'; unit='元/吨'; mode='cnmn';    match='^镁\(';    desc='上海金属现货报价（小金属），镁 1# 中间值。' }
  @{ id='bismuth';        name='铋';       cat='nonferrous'; unit='元/吨'; mode='cnmn';    match='^铋\('; desc='上海金属现货报价（小金属），铋 99.99% 中间值。' }
  @{ id='indium';         name='铟';       cat='nonferrous'; unit='元/千克'; mode='cnmn';  match='^铟\('; desc='上海金属现货报价（小金属），铟 99.99% 中间值。' }
  @{ id='gallium';        name='镓';       cat='nonferrous'; unit='元/千克'; mode='cnmn';  match='^镓\('; desc='上海金属现货报价（小金属），镓 99.99% 中间值。' }
  @{ id='cadmium';        name='镉';       cat='nonferrous'; unit='元/吨'; mode='cnmn';    match='^镉\(1#'; desc='上海金属现货报价（小金属），镉 99.99% 中间值。' }
  @{ id='tellurium';      name='碲';       cat='nonferrous'; unit='元/千克'; mode='cnmn';  match='^碲\(';        desc='上海金属现货报价（小金属），碲中间值。' }
  @{ id='titanium-sponge';name='海绵钛';   cat='nonferrous'; unit='元/吨'; mode='cnmn';    match='^海绵钛';    desc='上海金属现货报价（小金属），海绵钛中间值。' }
  @{ id='electrolytic-mn';name='电解锰';   cat='nonferrous'; unit='元/吨'; mode='cnmn';    match='^电解锰\(1#'; desc='上海金属现货报价（小金属），电解锰 1# 中间值。' }
  @{ id='silicon-metal';  name='金属硅';   cat='nonferrous'; unit='元/吨'; mode='cnmn';    match='^金属硅\(553#'; desc='上海金属现货报价（小金属），金属硅 553# 中间值。' }
  # LME 官方现货结算价（Westmetall 免费镜像）
  @{ id='lme-cu'; name='LME铜'; cat='nonferrous'; unit='美元/吨'; mode='westmetall'; sym='LME_Cu_cash'; desc='LME 铜现货结算价（美元/吨）。' }
  @{ id='lme-al'; name='LME铝'; cat='nonferrous'; unit='美元/吨'; mode='westmetall'; sym='LME_Al_cash'; desc='LME 铝现货结算价（美元/吨）。' }
  @{ id='lme-zn'; name='LME锌'; cat='nonferrous'; unit='美元/吨'; mode='westmetall'; sym='LME_Zn_cash'; desc='LME 锌现货结算价（美元/吨）。' }
  @{ id='lme-pb'; name='LME铅'; cat='nonferrous'; unit='美元/吨'; mode='westmetall'; sym='LME_Pb_cash'; desc='LME 铅现货结算价（美元/吨）。' }
  @{ id='lme-ni'; name='LME镍'; cat='nonferrous'; unit='美元/吨'; mode='westmetall'; sym='LME_Ni_cash'; desc='LME 镍现货结算价（美元/吨）。' }
  @{ id='lme-sn'; name='LME锡'; cat='nonferrous'; unit='美元/吨'; mode='westmetall'; sym='LME_Sn_cash'; desc='LME 锡现货结算价（美元/吨）。' }
  # 贵金属
  @{ id='au';             name='黄金';     cat='precious';  unit='元/克'; mode='official'; seriesId='au-sge-9999'; desc='上海黄金交易所 Au99.99 收盘价。' }
  @{ id='ag';             name='白银';     cat='precious';  unit='元/千克'; mode='official'; seriesId='ag-sge-td'; desc='上海黄金交易所 Ag(T+D) 收盘价。' }
  # 稀有/新能源
  @{ id='lithium-carbonate'; name='碳酸锂'; cat='rare';     unit='元/吨'; mode='sina';    sym='LC0';  grade='电池级'; region='全国'; desc='碳酸锂期货主力连续收盘价。' }
  @{ id='lithium-hydroxide'; name='氢氧化锂'; cat='rare';   unit='元/吨'; mode='cnmn';    match='^电池级氢氧化锂'; desc='上海金属现货报价（小金属），电池级氢氧化锂中间值。' }
  @{ id='industrial-silicon'; name='工业硅'; cat='rare';    unit='元/吨'; mode='sina';    sym='SI0';  grade='553# 通氧'; region='新疆'; desc='工业硅期货主力连续收盘价。' }
  @{ id='polysilicon';    name='多晶硅';   cat='rare';      unit='元/吨'; mode='sina';    sym='PS0';  grade='N型复投料'; region='全国'; desc='多晶硅期货主力连续收盘价。' }
  @{ id='tungsten-conc';  name='钨精矿';   cat='rare';      unit='元/吨'; mode='kekuang'; match='黑钨精矿'; desc='黑钨精矿 65% 报价。' }
  @{ id='apt';            name='仲钨酸铵'; cat='rare';      unit='元/吨'; mode='kekuang'; match='仲钨酸铵'; desc='仲钨酸铵 APT 报价。' }
  @{ id='moly-conc';      name='钼精矿';   cat='rare';      unit='元/吨度'; mode='kekuang'; match='钼精矿'; desc='钼精矿报价，元/吨度。' }
  # 非金属矿
  @{ id='fluorite';       name='萤石';     cat='nonmetal'; unit='元/吨'; mode='kekuang'; match='萤石'; grade='CaF₂ 97% 湿粉'; region='全国'; desc='萤石 97% 湿粉，不含税出厂价。' }
  @{ id='phosphate-rock'; name='磷矿石';   cat='nonmetal'; unit='元/吨'; mode='kekuang'; match='磷矿石'; grade='30% 品位'; region='湖北'; desc='磷矿石 30% 品位船板价。' }
  @{ id='graphite';       name='石墨';     cat='nonmetal'; unit='元/吨'; mode='kekuang'; match='鳞片石墨'; grade='-195 目'; region='全国'; desc='鳞片石墨 -195 目报价。' }
  @{ id='sulfur';         name='硫磺';     cat='nonmetal'; unit='元/吨'; mode='kekuang'; match='硫磺'; grade='进口颗粒'; region='全国'; desc='硫磺进口颗粒成交价。' }
)

$Categories = @(
  @{ id='ferrous';    name='黑色金属'; order=1; icon='▲'; desc='铁矿石、硅铁、锰硅' }
  @{ id='nonferrous'; name='有色金属'; order=2; icon='■'; desc='铜、铝、铅、锌、镍、锡、氧化铝、钴、锑、镁、铋、铟、镓、镉、碲、海绵钛、电解锰、金属硅、LME 六种基本金属' }
  @{ id='precious';   name='贵金属';   order=3; icon='◆'; desc='黄金、白银' }
  @{ id='rare';       name='稀有与新能源'; order=4; icon='●'; desc='碳酸锂、氢氧化锂、工业硅、多晶硅、钨精矿、仲钨酸铵、钼精矿' }
)

$Sources = @(
  @{ id='shfe';   name='上海期货交易所'; type='exchange'; trust='A'; freq='daily'; url='https://www.shfe.com.cn/'; note='交易所官方日行情，收盘价/结算价，主力合约按持仓量滚动选取。' }
  @{ id='sge';    name='上海黄金交易所'; type='exchange'; trust='A'; freq='daily'; url='https://www.sge.com.cn/'; note='交易所官方每日行情。' }
  @{ id='sina';   name='新浪财经';       type='media';    trust='B'; freq='daily'; url='https://finance.sina.com.cn/futures/'; note='国内期货主力连续日线，转载自交易所行情，用于无官方接口的品种。' }
  @{ id='cnmn';   name='中国有色网';     type='media';    trust='B'; freq='daily'; url='https://www.cnmn.com.cn/'; note='上海金属现货报价（小金属），每日 10:00/11:30 更新，取区间中间值。' }
  @{ id='kekuang';name='科矿网';         type='media';    trust='B'; freq='irregular'; url='http://www.kekuang.cn/'; note='稀土与非金属矿报价，不定期更新（偏周更）。' }
  @{ id='westmetall'; name='Westmetall（LME 镜像）'; type='media'; trust='B'; freq='daily'; url='https://www.westmetall.com/en/markdaten.php'; note='LME 官方现货结算价与库存的免费镜像，美元/吨，含约一年历史。' }
)

# ---------------- 适配器 ----------------

function Get-SinaHistory($sym) {
  $url = "https://stock2.finance.sina.com.cn/futures/api/jsonp.php/var%20_$sym=/InnerFuturesNewService.getDailyKLine?symbol=$sym"
  $txt = Get-WebText $url 'GBK' 'https://finance.sina.com.cn/'
  $i = $txt.IndexOf('=(')
  $j = $txt.LastIndexOf(')')
  if ($i -lt 0 -or $j -le $i) { throw "sina 返回格式异常: $sym" }
  $json = $txt.Substring($i + 2, $j - $i - 2)
  $arr = $json | ConvertFrom-Json
  $pts = @()
  foreach ($x in $arr) {
    $c = [double]$x.c
    if ($c -gt 0) { $pts += , @([string]$x.d, $c) }
  }
  return $pts
}

function Get-Westmetall($field) {
  # 返回按日期升序的 @($date, $value)；表头首行，日期形如 "23. November 2026"
  $url = "https://www.westmetall.com/en/markdaten.php?action=table&field=$field"
  $txt = Get-WebText $url 'UTF8'
  $rows = [regex]::Matches($txt, '(?s)<tr[^>]*>(.*?)</tr>') | ForEach-Object { $_.Groups[1].Value }
  $pts = @()
  foreach ($r in $rows) {
    $cells = [regex]::Matches($r, '(?s)<t[dh][^>]*>(.*?)</t[dh]>') | ForEach-Object { (($_.Groups[1].Value -replace '<[^>]+>', '') -replace '\s+', ' ').Trim() }
    if ($cells.Count -lt 3) { continue }
    $dm = [regex]::Match($cells[0], '^(\d{1,2})\.\s+([A-Za-z]+)\s+(\d{4})$')
    if (-not $dm.Success) { continue }
    $mon = @{ january=1; february=2; march=3; april=4; may=5; june=6; july=7; august=8; september=9; october=10; november=11; december=12 }[$dm.Groups[2].Value.ToLower()]
    if (-not $mon) { continue }
    $val = $null
    foreach ($c in $cells[1..($cells.Count - 1)]) {
      if ($c -match '^[\d,]+(\.\d+)?$') { $val = [double]($c -replace ',', ''); break }
    }
    if (-not $val -or $val -le 0) { continue }
    $d = ('{0:d4}-{1:d2}-{2:d2}' -f [int]$dm.Groups[3].Value, $mon, [int]$dm.Groups[1].Value)
    $pts += , @($d, $val)
  }
  $pts = @($pts | Sort-Object { $_[0] })
  return $pts
}

function Get-CnmnSpot() {  # 返回 hashtable: 名称 -> @{value=中间值; low; high; date; raw}
  # 注意：NewsMarket.html 实际是 UTF-8（meta 里写 GBK 是错的）
  $listUrl = 'https://www.cnmn.com.cn/NewsMarket.html'
  $html = Get-WebText $listUrl 'UTF8'
  $m = [regex]::Matches($html, '(?is)<a[^>]*href="([^"]*ShowNews1\.aspx\?id=(\d+))"[^>]*>(.*?)</a>')
  $cand = @()
  foreach ($x in $m) {
    $title = ($x.Groups[3].Value -replace '(?is)<[^>]+>', '').Trim()
    if ($title -match '小金属') { $cand += @{ id = $x.Groups[2].Value; title = $title } }
  }
  if ($cand.Count -eq 0) { throw '中国有色网：列表中没有“小金属”报价文章' }
  if ($cand.Count -eq 0) { throw '中国有色网：未在列表中定位到小金属报价文章' }
  $art = $cand[0]
  $artUrl = 'https://www.cnmn.com.cn/ShowNews1.aspx?id=' + $art.id
  $ah = Get-WebText $artUrl 'UTF8'
  $plain = Get-PlainText $ah
  $dm = [regex]::Match($plain, '(20\d{2})[-年/](\d{1,2})[-月/](\d{1,2})')
  $date = if ($dm.Success) { '{0:d4}-{1:d2}-{2:d2}' -f [int]$dm.Groups[1].Value, [int]$dm.Groups[2].Value, [int]$dm.Groups[3].Value } else { (Get-Date).ToString('yyyy-MM-dd') }
  $rows = [regex]::Matches($ah, '(?is)<tr[^>]*>(.*?)</tr>')
  $result = @{}
  foreach ($row in $rows) {
    $cells = [regex]::Matches($row.Groups[1].Value, '(?is)<t[dh][^>]*>(.*?)</t[dh]') | ForEach-Object {
      (Get-PlainText $_.Groups[1].Value)
    }
    $cells = @($cells)
    if ($cells.Count -lt 3) { continue }
    $name = $cells[0]
    $mid = $cells[2]
    if ($mid -notmatch '^\d+(\.\d+)?$') { continue }
    $range = $cells[1]
    $low = $null; $high = $null
    $rm = [regex]::Match($range, '(\d+(?:\.\d+)?)\s*[-–]\s*(\d+(?:\.\d+)?)')
    if ($rm.Success) { $low = [double]$rm.Groups[1].Value; $high = [double]$rm.Groups[2].Value }
    $result[$name] = @{ value = [double]$mid; low = $low; high = $high; date = $date; quote = $range; url = $artUrl; title = $art.title }
  }
  return @{ date = $date; rows = $result; url = $artUrl; title = $art.title }
}

function Get-KekuangIssues($maxIssues = 24) {
  # 从分类列表页收集 itemid（id 递增 ≈ 时间递增），取最新若干期
  $cats = @(4025, 4066, 4022, 4023, 4065)
  $ids = @{}
  foreach ($c in $cats) {
    foreach ($p in 1, 2, 3) {
      try {
        $html = Get-WebText "http://www.kekuang.cn/mobile/quote/list.php?catid=$c&page=$p" 'UTF8'
        foreach ($x in [regex]::Matches($html, 'itemid=(\d+)')) { $ids[[int]$x.Groups[1].Value] = $true }
        Start-Sleep -Milliseconds 150
      } catch { Log ("  [kekuang] 列表失败 catid=$c p=$p :: " + $_.Exception.Message) }
    }
  }
  $sorted = $ids.Keys | Sort-Object -Descending | Select-Object -First $maxIssues
  $items = @()
  foreach ($i in $sorted) { $items += @{ id = [string]$i; title = '' } }
  return $items
}

function Parse-KekuangArticle($itemid) {
  $url = "http://www.kekuang.cn/mobile/quote/show.php?itemid=$itemid"
  $html = Get-WebText $url 'UTF8'
  $tm = [regex]::Match($html, '(?is)<title>(.*?)</title>')
  $title = if ($tm.Success) { ($tm.Groups[1].Value -replace '\s+', ' ').Trim() } else { '' }
  $plain = Get-PlainText $html
  $dm = [regex]::Match($plain, '(20\d{2})[-年/](\d{1,2})[-月/](\d{1,2})')
  $date = if ($dm.Success) { '{0:d4}-{1:d2}-{2:d2}' -f [int]$dm.Groups[1].Value, [int]$dm.Groups[2].Value, [int]$dm.Groups[3].Value } else { (Get-Date).ToString('yyyy-MM-dd') }
  $rows = [regex]::Matches($html, '(?is)<tr[^>]*>(.*?)</tr>')
  $out = @()
  foreach ($row in $rows) {
    $cells = @([regex]::Matches($row.Groups[1].Value, '(?is)<t[dh][^>]*>(.*?)</t[dh]') | ForEach-Object {
      $c = Get-PlainText $_.Groups[1].Value
      return ($c -replace '^.*?box-sizing:\s*border-box !important;">', '').Trim()
    })
    if ($cells.Count -lt 4) { continue }
    $out += , $cells
  }
  return @{ date = $date; rows = $out; url = $url; title = $title; plain = $plain }
}

function Parse-PriceValue($text) {
  # 从 "32.4" / "1050-1080" / "3,750" / "33.3 万" 里取出一个代表值
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  $t = $text -replace ',', ''
  $m = [regex]::Match($t, '(\d+(?:\.\d+)?)\s*[-–~]\s*(\d+(?:\.\d+)?)')
  if ($m.Success) {
    $a = [double]$m.Groups[1].Value; $b = [double]$m.Groups[2].Value
    $v = ($a + $b) / 2
    if ($t -match '万') { $v = $v * 10000 }
    return $v
  }
  $m2 = [regex]::Match($t, '(\d+(?:\.\d+)?)')
  if ($m2.Success) {
    $v = [double]$m2.Groups[1].Value
    if ($t -match '万') { $v = $v * 10000 }
    return $v
  }
  return $null
}

# ---------------- 主流程 ----------------

Log '读取现有数据……'
$seriesOld = Read-JsonArray (Join-Path $DataDir 'series.json')
$officialIds = @('cu-shfe-cathode', 'al-shfe-a00', 'pb-shfe-1', 'zn-shfe-0', 'ni-shfe-1', 'sn-shfe-1', 'au-sge-9999', 'ag-sge-td')
$officialSeries = @{}
foreach ($s in $seriesOld) { if ($officialIds -contains $s.id) { $officialSeries[$s.id] = $s } }
Log ("  官方序列保留 " + $officialSeries.Count + " 条")

$today = (Get-Date).ToString('yyyy-MM-dd')
$seriesNew = @()
$varietyOut = @()
$missing = @()

# 1) 期货类
foreach ($v in $Varieties) {
  if ($v.mode -eq 'sina') {
    try {
      $pts = Get-SinaHistory $v.sym
      if ($pts.Count -eq 0) { throw '历史为空' }
      $cut = (Get-Date).AddDays(-$HistoryDays).ToString('yyyy-MM-dd')
      $pts = @($pts | Where-Object { $_[0] -ge $cut })
      if ($pts.Count -eq 0) { throw '区间内无数据' }
      $sid = $v.id + '-sina-main'
      $label = $v.name + ' 主力连续'
      $seriesNew += @{
        id = $sid; varietyId = $v.id; sourceId = 'sina'; label = $label
        spec = @{ grade = $v.grade; tax = '含税'; region = $v.region; delivery = '交易所交割'; currency = 'CNY' }
        unit = $v.unit; freq = 'daily'; updatedAt = $pts[$pts.Count - 1][0]
        historyStart = $pts[0][0]; points = $pts
      }
      $varietyOut += @{ id = $v.id; name = $v.name; category = $v.cat; unit = $v.unit; hasFutures = $true; defaultSeriesId = $sid; description = $v.desc; aliases = @() }
      Log ("  [sina] " + $v.name + " " + $pts.Count + " 点 " + $pts[0][0] + " ~ " + $pts[$pts.Count - 1][0])
    } catch {
      $missing += @{ variety = $v.name; reason = "新浪: " + $_.Exception.Message }
      Log ("  [sina] 失败 " + $v.name + " :: " + $_.Exception.Message)
    }
  }
}

# 2) LME 现货结算价（Westmetall）
foreach ($v in $Varieties) {
  if ($v.mode -ne 'westmetall') { continue }
  try {
    $pts = Get-Westmetall $v.sym
    if ($pts.Count -eq 0) { throw '无数据' }
    $cut = (Get-Date).AddDays(-$HistoryDays).ToString('yyyy-MM-dd')
    $pts = @($pts | Where-Object { $_[0] -ge $cut })
    if ($pts.Count -eq 0) { throw '区间内无数据' }
    $sid = $v.id + '-westmetall'
    $seriesNew += @{
      id = $sid; varietyId = $v.id; sourceId = 'westmetall'; label = ($v.name + ' 现货结算')
      spec = @{ grade = 'LME 标准'; tax = '不含税'; region = '伦敦'; delivery = '现货结算'; currency = 'USD' }
      unit = $v.unit; freq = 'daily'; updatedAt = $pts[$pts.Count - 1][0]
      historyStart = $pts[0][0]; points = $pts
    }
    $varietyOut += @{ id = $v.id; name = $v.name; category = $v.cat; unit = $v.unit; hasFutures = $true; defaultSeriesId = $sid; description = $v.desc; aliases = @() }
    Log ("  [westmetall] " + $v.name + " " + $pts.Count + " 点 " + $pts[0][0] + " ~ " + $pts[$pts.Count - 1][0])
  } catch {
    $missing += @{ variety = $v.name; reason = "westmetall: " + $_.Exception.Message }
    Log ("  [westmetall] 失败 " + $v.name + " :: " + $_.Exception.Message)
  }
}

# 3) 官方序列
foreach ($v in $Varieties) {
  if ($v.mode -ne 'official') { continue }
  $s = $officialSeries[$v.seriesId]
  if ($null -eq $s) { $missing += @{ variety = $v.name; reason = '官方序列缺失' }; continue }
  $seriesNew += $s
  $varietyOut += @{ id = $v.id; name = $v.name; category = $v.cat; unit = $v.unit; hasFutures = $true; defaultSeriesId = $s.id; description = $v.desc; aliases = @() }
  Log ("  [官方] " + $v.name + " " + $s.points.Count + " 点")
}

# 3) 中国有色网
$cnmnCache = Join-Path $PSScriptRoot '.cache/cnmn-latest.json'
$cnmn = $null
try {
  $cnmn = Get-CnmnSpot
  Log ("  [cnmn] " + $cnmn.title + " 日期=" + $cnmn.date + " 行数=" + $cnmn.rows.Count)
  if (-not $DryRun) {
    $cacheObj = @{ date = $cnmn.date; title = $cnmn.title; rows = $cnmn.rows }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cnmnCache) | Out-Null
    Write-JsonFile $cnmnCache $cacheObj
  }
} catch {
  Log ("  [cnmn] 失败 :: " + $_.Exception.Message)
  if (Test-Path $cnmnCache) {
    $c = [System.IO.File]::ReadAllText($cnmnCache, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $rows = @{}
    foreach ($p in $c.rows.PSObject.Properties) { $rows[$p.Name] = $p.Value }
    $cnmn = @{ date = $c.date; rows = $rows; title = $c.title; url = 'https://www.cnmn.com.cn/' }
    Log ("  [cnmn] 使用缓存 " + $c.date)
  }
}

if ($cnmn) {
  foreach ($v in $Varieties) {
    if ($v.mode -ne 'cnmn') { continue }
    $hit = $null
    foreach ($k in $cnmn.rows.Keys) { if ($k -like ('*' + $v.match + '*')) { $hit = $k; break } }
    if (-not $hit) {
      foreach ($k in $cnmn.rows.Keys) { if ($k -match $v.match) { $hit = $k; break } }
    }
    if (-not $hit) { $missing += @{ variety = $v.name; reason = '有色网未找到 ' + $v.match }; continue }
    $row = $cnmn.rows[$hit]
    $sid = $v.id + '-cnmn'
    $seriesNew += @{
      id = $sid; varietyId = $v.id; sourceId = 'cnmn'; label = ($v.name + ' ' + $hit)
      spec = @{ grade = $hit; tax = '含税'; region = '上海'; delivery = '现货'; currency = 'CNY'; quote = $row.quote }
      unit = $v.unit; freq = 'daily'; updatedAt = $cnmn.date
      historyStart = $cnmn.date; points = @(, @($cnmn.date, [double]$row.value))
    }
    $varietyOut += @{ id = $v.id; name = $v.name; category = $v.cat; unit = $v.unit; hasFutures = $false; defaultSeriesId = $sid; description = $v.desc; aliases = @() }
    Log ("  [cnmn] " + $v.name + " " + $row.quote + " -> " + $row.value + " (" + $cnmn.date + ")")
  }
}

# 4) 科矿网
$kk = $null
try {
  $issues = Get-KekuangIssues 60
  Log ("  [kekuang] 候选期次 " + $issues.Count)
  $allRows = @()
  foreach ($it in $issues) {
    try {
      $a = Parse-KekuangArticle $it.id
      Log ("    issue " + $it.id + " " + $a.date + " rows=" + $a.rows.Count + " :: " + $a.title)
      foreach ($r in $a.rows) { $allRows += , @{ cells = $r; date = $a.date; url = $a.url; title = $a.title; issue = $it.id; plain = $a.plain } }
      if ($a.rows.Count -eq 0 -and $a.plain) { $allRows += , @{ cells = @(); date = $a.date; url = $a.url; title = $a.title; issue = $it.id; plain = $a.plain } }
      Start-Sleep -Milliseconds 150
    } catch { Log ("    issue " + $it.id + " 失败 :: " + $_.Exception.Message) }
  }
  $kk = $allRows
} catch { Log ("  [kekuang] 失败 :: " + $_.Exception.Message) }

if ($kk) {
  foreach ($v in $Varieties) {
    if ($v.mode -ne 'kekuang') { continue }
    $points = @{}
    $lastRow = $null
    foreach ($blk in $kk) {
      $cells = @($blk.cells)
      $name = $null
      # 科矿表格列：品名 | 规格 | 报价 | 单位 | 涨跌 | 口径（个别期次列序不同，做兜底扫描）
      $val = $null; $quoteText = $null; $unitCell = $null
      if ($cells.Count -ge 3) {
        $name = $cells[0]
        if ($name -notmatch $v.match) { $name = $null }
      }
      if ($name) {
        $priceCells = @()
        if ($cells.Count -ge 4) { $priceCells += 2 }
        foreach ($i in 2, 3, 1, 4) { if ($i -lt $cells.Count -and ($priceCells -notcontains $i)) { $priceCells += $i } }
        foreach ($i in $priceCells) {
          $c = $cells[$i]
          if ($c -match '^\s*$') { continue }
          if ($c -match '^\s*(元|美元|万|CNY|USD)') { continue }
          if ($c -match '^\s*[\d\.,]+\s*[-–~]?\s*[\d\.,]*\s*万?\s*$') {
            $v2 = Parse-PriceValue $c
            if ($v2 -and $v2 -gt 0) { $val = $v2; $quoteText = $c; if ($i + 1 -lt $cells.Count) { $unitCell = $cells[$i + 1] }; break }
          }
        }
      }
      # 表格没命中时，退化为正文文本匹配：关键字后 120 字内的“数字 + 元/吨”
      if (-not $val -and $blk.plain) {
        $idx = $blk.plain.IndexOf(($v.match -replace '^\^', '' -replace '\\\(.*$', ''))
        if ($idx -ge 0) {
          $seg = $blk.plain.Substring($idx, [Math]::Min(140, $blk.plain.Length - $idx))
          $mm = [regex]::Match($seg, '([\d\.,]+(?:\s*[-–~]\s*[\d\.,]+)?)\s*万?\s*(元/吨度|元/吨|元/千克|元/克)')
          if ($mm.Success) {
            $val = Parse-PriceValue ($mm.Groups[1].Value + $(if ($seg.Substring($mm.Groups[1].Index - [Math]::Max(0, $mm.Groups[1].Index)) -match '万') { '' } else { '' }))
            $quoteText = $mm.Groups[1].Value
            $name = $mm.Groups[0].Value
          }
        }
      }
      if (-not $val) { continue }
      $d = $blk.date
      # 行内自带日期优先（如 "9/30 现货"）
      $dm = [regex]::Match(($cells -join ' '), '(\d{1,2})/(\d{1,2})\s*(现货|报价|合约)')
      if ($dm.Success) {
        $y = ([datetime]::ParseExact($blk.date, 'yyyy-MM-dd', $null)).Year
        $d = ('{0:d4}-{1:d2}-{2:d2}' -f $y, [int]$dm.Groups[1].Value, [int]$dm.Groups[2].Value)
      }
      if ($points.ContainsKey($d)) { continue }
      $points[$d] = $val
      $lastRow = @{ quote = $quoteText; url = $blk.url; title = $blk.title; name = $name }
    }
    if ($points.Count -eq 0) { $missing += @{ variety = $v.name; reason = '科矿网未找到 ' + $v.match }; Log ("  [kekuang] 缺失 " + $v.name); continue }
    $pl = @()
    foreach ($k in ($points.Keys | Sort-Object)) { $pl += , @($k, [double]$points[$k]) }
    $sid = $v.id + '-kekuang'
    $seriesNew += @{
      id = $sid; varietyId = $v.id; sourceId = 'kekuang'; label = ($v.name + ' ' + $lastRow.name)
      spec = @{ grade = $lastRow.name; tax = '未知'; region = '全国'; delivery = '现货'; currency = 'CNY' }
      unit = $v.unit; freq = 'irregular'; updatedAt = $pl[$pl.Count - 1][0]
      historyStart = $pl[0][0]; points = $pl
    }
    $varietyOut += @{ id = $v.id; name = $v.name; category = $v.cat; unit = $v.unit; hasFutures = $false; defaultSeriesId = $sid; description = $v.desc; aliases = @() }
    Log ("  [kekuang] " + $v.name + " " + $pl.Count + " 点 " + $pl[0][0] + " ~ " + $pl[$pl.Count - 1][0])
  }
}

# ---------------- 计算 catalog ----------------
function Get-Freshness($freq, $asOf) {
  if (-not $asOf) { return 'stopped' }
  $a = [datetime]::ParseExact($asOf, 'yyyy-MM-dd', $null)
  $days = ((Get-Date).Date - $a.Date).Days
  if ($days -lt 0) { $days = 0 }
  switch ($freq) {
    'daily'     { if ($days -le 1) { return 'normal' } elseif ($days -le 5) { return 'stale' } else { return 'stopped' } }
    'weekly'    { if ($days -le 7) { return 'normal' } elseif ($days -le 21) { return 'stale' } else { return 'stopped' } }
    'irregular' { if ($days -le 21) { return 'normal' } elseif ($days -le 45) { return 'stale' } else { return 'stopped' } }
    'monthly'   { if ($days -le 31) { return 'normal' } elseif ($days -le 62) { return 'stale' } else { return 'stopped' } }
    default     { return 'stale' }
  }
}

$catalog = @()
foreach ($s in $seriesNew) {
  $pts = @($s.points)
  if ($pts.Count -eq 0) { continue }
  $last = $pts[$pts.Count - 1]
  $prev = if ($pts.Count -ge 2) { $pts[$pts.Count - 2] } else { $null }
  $latest = [double]$last[1]
  $prevV = if ($prev) { [double]$prev[1] } else { $latest }
  $chg = $latest - $prevV
  $pct = if ($prevV -ne 0) { $chg / $prevV * 100 } else { 0 }
  $spark = @()
  $step = [Math]::Max(1, [Math]::Floor($pts.Count / 12))
  for ($i = $pts.Count - 1; $i -ge 0 -and $spark.Count -lt 12; $i -= $step) { $spark += [double]$pts[$i][1] }
  [array]::Reverse($spark)
  $v = $Varieties | Where-Object { $_.id -eq $s.varietyId } | Select-Object -First 1
  $catalog += @{
    seriesId = $s.id; varietyId = $s.varietyId
    varietyName = if ($v) { $v.name } else { $s.varietyId }
    category = if ($v) { $v.cat } else { 'other' }
    unit = $s.unit; latest = [math]::Round($latest, 4); prev = [math]::Round($prevV, 4)
    change = [math]::Round($chg, 4); changePct = [math]::Round($pct, 4)
    asOf = [string]$last[0]; sourceId = $s.sourceId
    trust = (($Sources | Where-Object { $_.id -eq $s.sourceId } | Select-Object -First 1).trust)
    freshness = Get-Freshness $s.freq ([string]$last[0])
    historyStart = $s.historyStart
    points = $pts.Count
    spark = $spark
  }
}

# 排序：按分类顺序 + 品种名
$catOrder = @{}
foreach ($c in $Categories) { $catOrder[$c.id] = $c.order }
$sortedVarieties = $varietyOut | Sort-Object -Property @{ Expression = { $catOrder[$_.category] } }, @{ Expression = { $_.id } }

$meta = @{
  siteName = '矿产品价格中枢'
  version = '2.0.0'
  generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
  dataAsOf = (($catalog | Sort-Object -Property asOf | Select-Object -Last 1).asOf)
  demoData = $false
  disclaimer = '价格口径以各来源为准，本站仅做汇总展示，不构成任何交易或投资建议。'
  countVariety = $sortedVarieties.Count
  countSeries = $catalog.Count
}

Log ''
Log ("品种 " + $sortedVarieties.Count + " / 序列 " + $catalog.Count + " / 数据截至 " + $meta.dataAsOf)

if ($missing.Count -gt 0) {
  Log '以下品种未取到数据：'
  foreach ($m in $missing) { Log ("  - " + $m.variety + "：" + $m.reason) }
}

if (-not $DryRun) {
  Write-JsonFile (Join-Path $DataDir 'categories.json') $Categories
  Write-JsonFile (Join-Path $DataDir 'sources.json') $Sources
  Write-JsonFile (Join-Path $DataDir 'varieties.json') $sortedVarieties
  Write-JsonFile (Join-Path $DataDir 'series.json') $seriesNew
  Write-JsonFile (Join-Path $DataDir 'catalog.json') $catalog
  Write-JsonFile (Join-Path $DataDir 'meta.json') $meta

  # bundle.js 兜底
  $jsonOpts = @{ Depth = 12 }
  $parts = @{
    meta = (ConvertTo-Json -InputObject $meta -Depth 12)
    categories = (ConvertTo-Json -InputObject $Categories -Depth 12)
    varieties = (ConvertTo-Json -InputObject $sortedVarieties -Depth 12)
    sources = (ConvertTo-Json -InputObject $Sources -Depth 12)
    series = (ConvertTo-Json -InputObject $seriesNew -Depth 12)
    catalog = (ConvertTo-Json -InputObject $catalog -Depth 12)
  }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('/* 自动生成：file:// 打开时的后备数据源。请勿手工编辑。 */')
  [void]$sb.AppendLine('window.__MINE_BUNDLE__ = {')
  $keys = @('meta', 'categories', 'varieties', 'sources', 'series', 'catalog')
  for ($i = 0; $i -lt $keys.Count; $i++) {
    $k = $keys[$i]
    $comma = if ($i -lt $keys.Count - 1) { ',' } else { '' }
    [void]$sb.AppendLine(('  ' + $k + ': ' + $parts[$k] + $comma))
  }
  [void]$sb.AppendLine('};')
  $bundle = [regex]::Replace($sb.ToString(), '\\u([0-9a-fA-F]{4})', {
    param($m)
    return [string][char][Convert]::ToInt32($m.Groups[1].Value, 16)
  })
  Write-TextFile (Join-Path $DataDir 'bundle.js') $bundle

  $logPath = Join-Path $DataDir 'update-log.json'
  $logArr = @(Read-JsonArray $logPath)
  $logArr += @{ at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'); varieties = $sortedVarieties.Count; series = $catalog.Count; dataAsOf = $meta.dataAsOf; missing = $missing }
  Write-JsonFile $logPath $logArr
  Log '已写入 6 个数据文件 + bundle.js'
} else {
  Log '（DryRun：未写盘）'
}
