<#
用途：为「矿产品价格中枢」示例站点生成 6 个数据文件（meta/categories/varieties/sources/series/catalog）
     以及 file:// 双击打开时使用的后备数据包 bundle.js（浏览器在 file:// 下无法 fetch 本地 JSON）。
输入：本脚本内定义的品种与序列配置（示例数据，量级参考现实行情，非真实报价）。
输出：<站点根>/data/*.json、<站点根>/data/bundle.js
依赖：Windows PowerShell 5.1 及以上，无需 Node / Python。
运行：powershell -NoProfile -ExecutionPolicy Bypass -File tools\gen_data.ps1
说明：伪随机数由 seriesId 派生种子，结果可复现；改配置后重跑即可，不要再手工改 JSON。
#>

$ErrorActionPreference = 'Stop'

$Root    = Split-Path -Parent $PSScriptRoot          # site\
$DataDir = Join-Path $Root 'data'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

$DataAsOf = Get-Date -Date '2026-11-19'               # 全站"数据截至"基准日

# ---------------------------------------------------------------- 工具函数

function Get-Seed([string]$s) {
    $h = [long]17
    foreach ($c in $s.ToCharArray()) { $h = ($h * 31 + [int]$c) % 2147483647 }
    [int]$h
}

function Get-Gauss([System.Random]$r) {
    $u1 = 1.0 - $r.NextDouble()
    $u2 = $r.NextDouble()
    [math]::Sqrt(-2.0 * [math]::Log($u1)) * [math]::Cos(2.0 * [math]::PI * $u2)
}

function Get-BizDates([datetime]$end, [int]$count) {
    $list = New-Object System.Collections.ArrayList
    $d = $end
    while ($list.Count -lt $count) {
        if ($d.DayOfWeek -ne 'Saturday' -and $d.DayOfWeek -ne 'Sunday') { [void]$list.Insert(0, $d) }
        $d = $d.AddDays(-1)
    }
    , $list
}

function Get-WeeklyDates([datetime]$end, [int]$count) {
    $d = $end
    while ($d.DayOfWeek -ne 'Friday') { $d = $d.AddDays(-1) }
    $list = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $count; $i++) { [void]$list.Insert(0, $d.AddDays(-7 * $i)) }
    , $list
}

function Get-MonthlyDates([datetime]$end, [int]$count) {
    $list = New-Object System.Collections.ArrayList
    $ms = Get-Date -Year $end.Year -Month $end.Month -Day 1
    for ($i = 0; $i -lt $count; $i++) {
        $d = $ms.AddDays(-1)
        while ($d.DayOfWeek -eq 'Saturday' -or $d.DayOfWeek -eq 'Sunday') { $d = $d.AddDays(-1) }
        [void]$list.Insert(0, $d)
        $ms = $ms.AddMonths(-1)
    }
    , $list
}

function Get-BizDaysBetween([datetime]$from, [datetime]$to) {
    if ($to -le $from) { return 0 }
    $n = 0
    $d = $from.AddDays(1)
    while ($d -le $to) {
        if ($d.DayOfWeek -ne 'Saturday' -and $d.DayOfWeek -ne 'Sunday') { $n++ }
        $d = $d.AddDays(1)
    }
    $n
}

function Get-Freshness([string]$freq, [datetime]$asOf, [datetime]$ref) {
    $days = ([datetime]::new($asOf.Year, $asOf.Month, $asOf.Day) - [datetime]::new($ref.Year, $ref.Month, $ref.Day)).Days
    switch ($freq) {
        'daily' {
            $bd = Get-BizDaysBetween $asOf $ref
            if ($bd -le 1) { 'normal' } elseif ($bd -le 5) { 'stale' } else { 'stopped' }
        }
        'weekly' { if ($days -le 7) { 'normal' } elseif ($days -le 21) { 'stale' } else { 'stopped' } }
        'monthly' { if ($days -le 31) { 'normal' } elseif ($days -le 62) { 'stale' } else { 'stopped' } }
        default { 'normal' }
    }
}

function New-Points($def) {
    $end = $DataAsOf.AddDays(-1 * [int]$def.endOffset)
    $dates = switch ($def.freq) {
        'daily'   { Get-BizDates   $end ([int]$def.count) }
        'weekly'  { Get-WeeklyDates $end ([int]$def.count) }
        'monthly' { Get-MonthlyDates $end ([int]$def.count) }
    }
    $r = [System.Random]::new((Get-Seed $def.id))
    $n = $dates.Count
    $prices = [double[]]::new($n)
    $prices[$n - 1] = [double]$def.base              # 末端锚定在配置价，视觉上更贴近现实量级
    for ($i = $n - 2; $i -ge 0; $i--) {
        $shock = (Get-Gauss $r) * [double]$def.vol
        $step  = 1.0 + $shock + [double]$def.drift
        if ($step -lt 0.5) { $step = 0.5 }
        $prices[$i] = $prices[$i + 1] / $step
    }
    $skip = @()
    if ($def.gaps) { $skip = @($def.gaps) }
    $pts = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $n; $i++) {
        if ($skip -contains $i) { continue }
        $v = [math]::Round($prices[$i], [int]$def.dec)
        if ([int]$def.dec -eq 0) { $v = [long]$v }
        [void]$pts.Add(@($dates[$i].ToString('yyyy-MM-dd'), $v))
    }
    , $pts
}

# ---------------------------------------------------------------- 大类

$Categories = @(
    [ordered]@{ id = 'ferrous';    name = '黑色金属'; order = 1; icon = '▲'; desc = '铁矿石、锰矿、铬矿' }
    [ordered]@{ id = 'nonferrous'; name = '有色金属'; order = 2; icon = '■'; desc = '铜、铝、铅、锌、镍、锡、锑、镁' }
    [ordered]@{ id = 'precious';   name = '贵金属';   order = 3; icon = '◆'; desc = '黄金、白银' }
    [ordered]@{ id = 'rare';       name = '稀有稀土'; order = 4; icon = '●'; desc = '碳酸锂、钴、氧化镨钕、钨精矿' }
    [ordered]@{ id = 'nonmetal';   name = '非金属矿'; order = 5; icon = '○'; desc = '萤石、磷矿石、石墨' }
)

# ---------------------------------------------------------------- 来源

$Sources = @(
    [ordered]@{ id = 'shfe';  name = '上海期货交易所'; type = 'exchange';    trust = 'A'; freq = 'daily';   url = 'https://www.shfe.com.cn'; note = '官方结算行情' }
    [ordered]@{ id = 'dce';   name = '大连商品交易所'; type = 'exchange';    trust = 'A'; freq = 'daily';   url = 'http://www.dce.com.cn';   note = '官方结算行情' }
    [ordered]@{ id = 'gfex';  name = '广州期货交易所'; type = 'exchange';    trust = 'A'; freq = 'daily';   url = 'http://www.gfex.com.cn';  note = '官方结算行情' }
    [ordered]@{ id = 'sge';   name = '上海黄金交易所'; type = 'exchange';    trust = 'A'; freq = 'daily';   url = 'https://www.sge.com.cn';  note = '官方行情' }
    [ordered]@{ id = 'smm';   name = '上海有色网';     type = 'agency';      trust = 'B'; freq = 'weekly';  url = 'https://www.smm.cn';      note = '商业机构现货报价' }
    [ordered]@{ id = 'baiinfo'; name = '百川盈孚';     type = 'agency';      trust = 'B'; freq = 'weekly';  url = 'https://www.baiinfo.com'; note = '商业机构现货报价' }
    [ordered]@{ id = 'kq81';  name = '矿权资源网';     type = 'media';       trust = 'C'; freq = 'weekly';  url = 'http://www.kq81.com';     note = '行业媒体公开报价' }
    [ordered]@{ id = 'manual'; name = '内部录入';      type = 'manual';      trust = 'D'; freq = 'manual';  url = $null;                     note = '人工询价，仅供参考' }
)

# ---------------------------------------------------------------- 品种（20）

$Varieties = @(
    [ordered]@{ id = 'iron-ore';             name = '铁矿石';   aliases = @('铁矿','铁精粉','Iron Ore','Fe');        category = 'ferrous';    hasFutures = $true;  unit = '元/吨';   defaultSeriesId = 'iron-ore-dce';      description = '62% 品位粉矿，干基，港口自提。' }
    [ordered]@{ id = 'manganese-ore';        name = '锰矿';     aliases = @('锰矿石','Manganese Ore','Mn');          category = 'ferrous';    hasFutures = $false; unit = '元/吨度'; defaultSeriesId = 'mn-baiinfo';        description = '44% 澳矿，吨度计价。' }
    [ordered]@{ id = 'chrome-ore';           name = '铬矿';     aliases = @('铬矿石','Chrome Ore','Cr');             category = 'ferrous';    hasFutures = $false; unit = '美元/吨'; defaultSeriesId = 'cr-smm';            description = '40% 南非粉矿，CIF 中国主港。' }
    [ordered]@{ id = 'cu';                   name = '铜';       aliases = @('电解铜','阴极铜','Copper','Cu');        category = 'nonferrous'; hasFutures = $true;  unit = '元/吨';   defaultSeriesId = 'cu-shfe-cathode';   description = '1# 阴极铜，含税，上海仓库自提。' }
    [ordered]@{ id = 'al';                   name = '铝';       aliases = @('电解铝','铝锭','Aluminum','Al');        category = 'nonferrous'; hasFutures = $true;  unit = '元/吨';   defaultSeriesId = 'al-shfe-a00';       description = 'A00 铝锭，含税。' }
    [ordered]@{ id = 'pb';                   name = '铅';       aliases = @('电解铅','铅锭','Lead','Pb');            category = 'nonferrous'; hasFutures = $true;  unit = '元/吨';   defaultSeriesId = 'pb-shfe-1';         description = '1# 铅锭，含税。' }
    [ordered]@{ id = 'zn';                   name = '锌';       aliases = @('电解锌','锌锭','Zinc','Zn');            category = 'nonferrous'; hasFutures = $true;  unit = '元/吨';   defaultSeriesId = 'zn-shfe-0';         description = '0# 锌锭，含税。' }
    [ordered]@{ id = 'ni';                   name = '镍';       aliases = @('电解镍','镍板','Nickel','Ni');          category = 'nonferrous'; hasFutures = $true;  unit = '元/吨';   defaultSeriesId = 'ni-shfe-1';         description = '1# 电解镍，含税。' }
    [ordered]@{ id = 'sn';                   name = '锡';       aliases = @('电解锡','锡锭','Tin','Sn');             category = 'nonferrous'; hasFutures = $true;  unit = '元/吨';   defaultSeriesId = 'sn-shfe-1';         description = '1# 锡锭，含税。' }
    [ordered]@{ id = 'sb';                   name = '锑';       aliases = @('锑锭','Antimony','Sb');                 category = 'nonferrous'; hasFutures = $false; unit = '元/吨';   defaultSeriesId = 'sb-smm-1';          description = '1# 锑锭，含税，湖南主产区。' }
    [ordered]@{ id = 'mg';                   name = '镁';       aliases = @('镁锭','Magnesium','Mg');                category = 'nonferrous'; hasFutures = $false; unit = '元/吨';   defaultSeriesId = 'mg-smm-999';        description = '99.9% 镁锭，含税，府谷出厂。' }
    [ordered]@{ id = 'au';                   name = '黄金';     aliases = @('金','Gold','Au','Au99.99');             category = 'precious';   hasFutures = $true;  unit = '元/克';   defaultSeriesId = 'au-sge-9999';       description = 'Au99.99 现货，上海黄金交易所。' }
    [ordered]@{ id = 'ag';                   name = '白银';     aliases = @('银','Silver','Ag','Ag(T+D)');           category = 'precious';   hasFutures = $true;  unit = '元/千克'; defaultSeriesId = 'ag-sge-td';         description = 'Ag(T+D) 递延合约。' }
    [ordered]@{ id = 'lithium-carbonate';    name = '碳酸锂';   aliases = @('锂盐','Li2CO3','Lithium Carbonate');    category = 'rare';       hasFutures = $true;  unit = '元/吨';   defaultSeriesId = 'lc-gfex-2407';      description = '电池级碳酸锂，主力合约与现货并存。' }
    [ordered]@{ id = 'co';                   name = '钴';       aliases = @('电解钴','Cobalt','Co');                 category = 'rare';       hasFutures = $false; unit = '元/吨';   defaultSeriesId = 'co-smm-998';        description = '电解钴 ≥99.8%，含税。' }
    [ordered]@{ id = 'prnd-oxide';           name = '氧化镨钕'; aliases = @('镨钕氧化物','PrNd Oxide','NdPr');        category = 'rare';       hasFutures = $false; unit = '元/吨';   defaultSeriesId = 'prnd-smm-99';       description = '≥99% 氧化镨钕，含税。' }
    [ordered]@{ id = 'tungsten-concentrate'; name = '钨精矿';   aliases = @('黑钨精矿','Tungsten','W');              category = 'rare';       hasFutures = $false; unit = '元/吨';   defaultSeriesId = 'w-smm-65';          description = '65% 黑钨精矿，含税。' }
    [ordered]@{ id = 'fluorite';             name = '萤石';     aliases = @('氟石','CaF2','Fluorite','氟化钙');       category = 'nonmetal';   hasFutures = $false; unit = '元/吨';   defaultSeriesId = 'fluorite-kq81-97';  description = 'CaF₂ 97% 湿粉，不含税，出厂价。' }
    [ordered]@{ id = 'phosphate-rock';       name = '磷矿石';   aliases = @('磷矿','Phosphate Rock','P2O5');          category = 'nonmetal';   hasFutures = $false; unit = '元/吨';   defaultSeriesId = 'p-rock-kq81-30';    description = '30% 品位，坑口价。' }
    [ordered]@{ id = 'graphite';             name = '石墨';     aliases = @('鳞片石墨','Graphite','C');              category = 'nonmetal';   hasFutures = $false; unit = '元/吨';   defaultSeriesId = 'graphite-kq81-195'; description = '鳞片石墨 -195 目，含税。' }
)

# ---------------------------------------------------------------- 序列（23）
# gaps = 刻意挖掉的下标，用于验证"断点不插值"规则

$SeriesDefs = @(
    # --- 日频：期货/交易所 ---
    @{ id = 'iron-ore-dce';      varietyId = 'iron-ore';          sourceId = 'dce';   label = '铁矿石 · 62% 粉矿 · 干基 · 日照港';     spec = @{ grade = '62% Fe'; tax = '含税'; region = '日照港'; delivery = '港口自提'; currency = 'CNY' }; unit = '元/吨';   freq = 'daily';   base = 786;    vol = 0.013; drift = 0.0002; dec = 0; count = 260; endOffset = 0; gaps = @() }
    @{ id = 'cu-shfe-cathode';   varietyId = 'cu';                sourceId = 'shfe';  label = '阴极铜 · 上海 · 含税';                  spec = @{ grade = '≥99.95%'; tax = '含税'; region = '上海'; delivery = '仓库自提'; currency = 'CNY' }; unit = '元/吨'; freq = 'daily'; base = 72400; vol = 0.011; drift = 0.0003; dec = 0; count = 260; endOffset = 0; gaps = @(120,121,122) }
    @{ id = 'cu-smm-gd';         varietyId = 'cu';                sourceId = 'smm';   label = '电解铜 · 广东 · 不含税';                spec = @{ grade = '≥99.95%'; tax = '不含税'; region = '广东'; delivery = '厂提'; currency = 'CNY' }; unit = '元/吨'; freq = 'daily'; base = 62800; vol = 0.012; drift = 0.0003; dec = 0; count = 180; endOffset = 1; gaps = @() }
    @{ id = 'al-shfe-a00';       varietyId = 'al';                sourceId = 'shfe';  label = 'A00 铝锭 · 上海 · 含税';                spec = @{ grade = 'A00'; tax = '含税'; region = '上海'; delivery = '仓库自提'; currency = 'CNY' }; unit = '元/吨'; freq = 'daily'; base = 20640; vol = 0.009; drift = 0.0001; dec = 0; count = 260; endOffset = 0; gaps = @() }
    @{ id = 'pb-shfe-1';         varietyId = 'pb';                sourceId = 'shfe';  label = '1# 铅锭 · 上海 · 含税';                  spec = @{ grade = '1# 铅'; tax = '含税'; region = '上海'; delivery = '仓库自提'; currency = 'CNY' }; unit = '元/吨'; freq = 'daily'; base = 17320; vol = 0.010; drift = 0.0001; dec = 0; count = 260; endOffset = 0; gaps = @() }
    @{ id = 'zn-shfe-0';         varietyId = 'zn';                sourceId = 'shfe';  label = '0# 锌锭 · 上海 · 含税';                  spec = @{ grade = '0# 锌'; tax = '含税'; region = '上海'; delivery = '仓库自提'; currency = 'CNY' }; unit = '元/吨'; freq = 'daily'; base = 22810; vol = 0.012; drift = 0.0001; dec = 0; count = 260; endOffset = 0; gaps = @() }
    @{ id = 'ni-shfe-1';         varietyId = 'ni';                sourceId = 'shfe';  label = '1# 电解镍 · 上海 · 含税';                spec = @{ grade = '1# 镍'; tax = '含税'; region = '上海'; delivery = '仓库自提'; currency = 'CNY' }; unit = '元/吨'; freq = 'daily'; base = 127860; vol = 0.017; drift = 0.0001; dec = 0; count = 260; endOffset = 0; gaps = @() }
    @{ id = 'sn-shfe-1';         varietyId = 'sn';                sourceId = 'shfe';  label = '1# 锡锭 · 上海 · 含税';                  spec = @{ grade = '1# 锡'; tax = '含税'; region = '上海'; delivery = '仓库自提'; currency = 'CNY' }; unit = '元/吨'; freq = 'daily'; base = 245300; vol = 0.016; drift = 0.0002; dec = 0; count = 260; endOffset = 0; gaps = @() }
    @{ id = 'au-sge-9999';       varietyId = 'au';                sourceId = 'sge';   label = 'Au99.99 · 上海黄金交易所';              spec = @{ grade = 'Au99.99'; tax = '含税'; region = '上海'; delivery = '实物交割'; currency = 'CNY' }; unit = '元/克'; freq = 'daily'; base = 615.42; vol = 0.008; drift = 0.0004; dec = 2; count = 260; endOffset = 0; gaps = @() }
    @{ id = 'ag-sge-td';         varietyId = 'ag';                sourceId = 'sge';   label = 'Ag(T+D) · 递延合约';                    spec = @{ grade = 'Ag ≥99.9%'; tax = '含税'; region = '上海'; delivery = '递延交收'; currency = 'CNY' }; unit = '元/千克'; freq = 'daily'; base = 8246; vol = 0.014; drift = 0.0003; dec = 0; count = 260; endOffset = 0; gaps = @() }
    @{ id = 'lc-gfex-2407';      varietyId = 'lithium-carbonate'; sourceId = 'gfex';  label = '碳酸锂 · 主力合约';                     spec = @{ grade = '电池级'; tax = '含税'; region = '广期所'; delivery = '厂库交割'; currency = 'CNY' }; unit = '元/吨'; freq = 'daily'; base = 76450; vol = 0.021; drift = -0.0004; dec = 0; count = 260; endOffset = 0; gaps = @(88,89) }
    @{ id = 'lc-smm-battery';    varietyId = 'lithium-carbonate'; sourceId = 'smm';   label = '碳酸锂 · 电池级 · 现货';                spec = @{ grade = '电池级 99.5%'; tax = '含税'; region = '华东'; delivery = '送到'; currency = 'CNY' }; unit = '元/吨'; freq = 'daily'; base = 78100; vol = 0.019; drift = -0.0004; dec = 0; count = 180; endOffset = 2; gaps = @() }

    # --- 周频：机构/媒体 ---
    @{ id = 'mn-baiinfo';        varietyId = 'manganese-ore';     sourceId = 'baiinfo'; label = '锰矿 · 44% 澳矿 · 吨度';              spec = @{ grade = '44% Mn'; tax = '含税'; region = '天津港'; delivery = '港口自提'; currency = 'CNY' }; unit = '元/吨度'; freq = 'weekly'; base = 32.4;  vol = 0.016; drift = 0.0008; dec = 1; count = 65; endOffset = 0; gaps = @(28,29,30) }
    @{ id = 'cr-smm';            varietyId = 'chrome-ore';        sourceId = 'smm';   label = '铬矿 · 40% 南非粉 · CIF';             spec = @{ grade = '40% Cr2O3'; tax = '不含税'; region = '中国主港'; delivery = 'CIF'; currency = 'USD' }; unit = '美元/吨'; freq = 'weekly'; base = 265.5; vol = 0.014; drift = 0.0006; dec = 1; count = 65; endOffset = 15; gaps = @() }
    @{ id = 'sb-smm-1';          varietyId = 'sb';                sourceId = 'smm';   label = '1# 锑锭 · 湖南 · 含税';                spec = @{ grade = '1# 锑'; tax = '含税'; region = '湖南'; delivery = '出厂'; currency = 'CNY' }; unit = '元/吨'; freq = 'weekly'; base = 79200; vol = 0.018; drift = 0.0012; dec = 0; count = 65; endOffset = 0; gaps = @() }
    @{ id = 'mg-smm-999';        varietyId = 'mg';                sourceId = 'smm';   label = '99.9% 镁锭 · 府谷 · 含税';            spec = @{ grade = '99.9% Mg'; tax = '含税'; region = '府谷'; delivery = '出厂'; currency = 'CNY' }; unit = '元/吨'; freq = 'weekly'; base = 18560; vol = 0.013; drift = 0.0004; dec = 0; count = 65; endOffset = 0; gaps = @() }
    @{ id = 'co-smm-998';        varietyId = 'co';                sourceId = 'smm';   label = '电解钴 · ≥99.8% · 含税';              spec = @{ grade = '≥99.8% Co'; tax = '含税'; region = '全国'; delivery = '出厂'; currency = 'CNY' }; unit = '元/吨'; freq = 'weekly'; base = 178500; vol = 0.015; drift = -0.0003; dec = 0; count = 65; endOffset = 0; gaps = @() }
    @{ id = 'prnd-smm-99';       varietyId = 'prnd-oxide';        sourceId = 'smm';   label = '氧化镨钕 · ≥99% · 含税';              spec = @{ grade = '≥99% PrNd'; tax = '含税'; region = '江西'; delivery = '出厂'; currency = 'CNY' }; unit = '元/吨'; freq = 'weekly'; base = 418000; vol = 0.017; drift = 0.0005; dec = 0; count = 65; endOffset = 0; gaps = @() }
    @{ id = 'w-smm-65';          varietyId = 'tungsten-concentrate'; sourceId = 'smm'; label = '65% 黑钨精矿 · 江西 · 含税';         spec = @{ grade = '65% WO3'; tax = '含税'; region = '江西'; delivery = '出厂'; currency = 'CNY' }; unit = '元/吨'; freq = 'weekly'; base = 142300; vol = 0.011; drift = 0.0007; dec = 0; count = 65; endOffset = 0; gaps = @() }
    @{ id = 'fluorite-kq81-97';  varietyId = 'fluorite';          sourceId = 'kq81';  label = '萤石 · CaF₂ 97% 湿粉 · 不含税 · 出厂'; spec = @{ grade = 'CaF₂ 97%'; tax = '不含税'; region = '江西/内蒙古'; delivery = '出厂'; currency = 'CNY' }; unit = '元/吨'; freq = 'weekly'; base = 3500; vol = 0.012; drift = 0.0006; dec = 0; count = 65; endOffset = 0; gaps = @(40,41) }
    @{ id = 'fluorite-baiinfo-97'; varietyId = 'fluorite';       sourceId = 'baiinfo'; label = '萤石 · CaF₂ 97% 干粉 · 含税 · 到厂';  spec = @{ grade = 'CaF₂ 97% 干粉'; tax = '含税'; region = '华东'; delivery = '到厂'; currency = 'CNY' }; unit = '元/吨'; freq = 'weekly'; base = 3820; vol = 0.011; drift = 0.0006; dec = 0; count = 65; endOffset = 0; gaps = @() }
    @{ id = 'p-rock-kq81-30';    varietyId = 'phosphate-rock';    sourceId = 'kq81';  label = '磷矿石 · 30% 品位 · 坑口';            spec = @{ grade = 'P2O5 30%'; tax = '不含税'; region = '贵州'; delivery = '坑口'; currency = 'CNY' }; unit = '元/吨'; freq = 'weekly'; base = 1085; vol = 0.010; drift = 0.0009; dec = 0; count = 65; endOffset = 30; gaps = @(20,21,22) }

    # --- 月频：冷门非金属 ---
    @{ id = 'graphite-kq81-195'; varietyId = 'graphite';          sourceId = 'kq81';  label = '鳞片石墨 · -195 目 · 含税';           spec = @{ grade = '-195 目'; tax = '含税'; region = '黑龙江'; delivery = '出厂'; currency = 'CNY' }; unit = '元/吨'; freq = 'monthly'; base = 3860; vol = 0.022; drift = 0.0004; dec = 0; count = 24; endOffset = 68; gaps = @(9) }
)

# ---------------------------------------------------------------- 生成

$Series  = New-Object System.Collections.ArrayList
$Catalog = New-Object System.Collections.ArrayList

foreach ($def in $SeriesDefs) {
    $pts = New-Points $def
    if ($pts.Count -lt 2) { throw "序列 $($def.id) 点数不足" }

    $last  = $pts[$pts.Count - 1]
    $prevP = $pts[$pts.Count - 2]
    $latest = [double]$last[1]
    $prev   = [double]$prevP[1]
    $change = $latest - $prev
    $pct    = if ($prev -ne 0) { [math]::Round(($latest - $prev) / $prev * 100, 2) } else { 0 }
    $asOf   = [datetime]::ParseExact([string]$last[0], 'yyyy-MM-dd', $null)
    $fresh  = Get-Freshness $def.freq $DataAsOf $asOf

    $sparkStart = [math]::Max(0, $pts.Count - 12)
    $spark = @()
    for ($i = $sparkStart; $i -lt $pts.Count; $i++) { $spark += $pts[$i][1] }

    [void]$Series.Add([ordered]@{
        id        = $def.id
        varietyId = $def.varietyId
        sourceId  = $def.sourceId
        label     = $def.label
        spec      = [ordered]@{
            grade    = $def.spec.grade
            tax      = $def.spec.tax
            region   = $def.spec.region
            delivery = $def.spec.delivery
            currency = $def.spec.currency
        }
        unit      = $def.unit
        freq      = $def.freq
        updatedAt = $last[0]
        points    = $pts
    })

    [void]$Catalog.Add([ordered]@{
        seriesId    = $def.id
        varietyId   = $def.varietyId
        varietyName = ($Varieties | Where-Object { $_.id -eq $def.varietyId }).name
        category    = ($Varieties | Where-Object { $_.id -eq $def.varietyId }).category
        unit        = $def.unit
        latest      = $latest
        prev        = $prev
        change      = $change
        changePct   = $pct
        asOf        = $last[0]
        sourceId    = $def.sourceId
        trust       = ($Sources | Where-Object { $_.id -eq $def.sourceId }).trust
        freshness   = $fresh
        spark       = $spark
    })
}

$Meta = [ordered]@{
    siteName    = '矿产品价格中枢'
    version     = '1.2.0'
    generatedAt = '2026-11-20T08:00:00+08:00'
    dataAsOf    = $DataAsOf.ToString('yyyy-MM-dd')
    demoData    = $true
    disclaimer  = '本站当前使用示例数据，仅供界面与流程演示，不构成任何交易或投资建议。价格口径以各来源为准。'
}

# ---------------------------------------------------------------- 写盘

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function ConvertTo-JsonText($obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 20
    # PowerShell 5.1 会把中文转义成 \uXXXX，这里还原成原始字符，保证数据文件可读、可手工维护
    $json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', {
            param($m)
            [string][char][Convert]::ToInt32($m.Groups[1].Value, 16)
        })
    $json
}

function Write-Json($obj, [string]$name) {
    $path = Join-Path $DataDir $name
    $json = ConvertTo-JsonText $obj
    [System.IO.File]::WriteAllText($path, $json, $Utf8NoBom)
    Write-Host ("  {0,-18} {1,8:N0} B" -f $name, (Get-Item $path).Length)
}

Write-Host '写出数据文件：'
Write-Json $Meta       'meta.json'
Write-Json @($Categories) 'categories.json'
Write-Json @($Varieties)  'varieties.json'
Write-Json @($Sources)    'sources.json'
Write-Json @($Series)     'series.json'
Write-Json @($Catalog)    'catalog.json'

# file:// 后备数据包：浏览器在 file:// 下不能 fetch 本地 JSON，用 <script> 注入同一份数据
$Bundle = [ordered]@{
    meta       = $Meta
    categories = @($Categories)
    varieties  = @($Varieties)
    sources    = @($Sources)
    series     = @($Series)
    catalog    = @($Catalog)
}
$bundlePath = Join-Path $DataDir 'bundle.js'
$bundleJson = ConvertTo-JsonText $Bundle
[System.IO.File]::WriteAllText($bundlePath, ("/* 由 tools/gen_data.ps1 自动生成，请勿手工编辑 */`nwindow.__MINE_BUNDLE__ = $bundleJson;"), $Utf8NoBom)
Write-Host ("  {0,-18} {1,8:N0} B  (file:// 后备)" -f 'bundle.js', (Get-Item $bundlePath).Length)

# ---------------------------------------------------------------- 自检输出

Write-Host ''
Write-Host ('品种 {0} 个 ｜ 序列 {1} 条 ｜ 数据截至 {2}' -f $Varieties.Count, $Series.Count, $DataAsOf.ToString('yyyy-MM-dd'))
Write-Host ''
Write-Host ('{0,-24} {1,-6} {2,-8} {3,10} {4,8} {5,-8} {6,4}' -f '序列', '频率', '截至', '最新', '涨跌%', '新鲜度', '点数')
foreach ($c in $Catalog) {
    $s = $Series | Where-Object { $_.id -eq $c.seriesId }
    Write-Host ('{0,-24} {1,-6} {2,-8} {3,10} {4,8} {5,-8} {6,4}' -f $c.seriesId, $s.freq, $c.asOf, $c.latest, $c.changePct, $c.freshness, $s.points.Count)
}
