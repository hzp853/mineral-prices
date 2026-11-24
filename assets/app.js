/* 矿产品价格中枢 · 应用逻辑
 * 数据层（fetch → bundle 回退）、hash 路由、格式化、页面渲染、自选、导出。
 */
(function () {
  'use strict';

  var DAY = 86400000;
  var FILES = ['meta', 'categories', 'varieties', 'sources', 'series', 'catalog'];
  var LS_WATCH = 'mine.watchlist.v1';
  var LS_THEME = 'mine.theme';

  var D = { meta: null, categories: [], varieties: [], sources: [], series: [], catalog: [] };
  var MAP = { category: {}, variety: {}, source: {}, series: {}, cat: {} };

  var state = {
    range: '365',
    homeSort: 'chg-desc',
    rankTab: 'up',
    cmpIds: ['cu', 'al', 'iron-ore'],
    cmpRange: '365'
  };

  var chartObj = null;
  var pendingChart = null;
  var keepScrollFlag = false;
  var curRoute = null;

  /* ---------------------------------------------------------------- 工具 */

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function group(v, dec) {
    var s = Number(v).toFixed(dec);
    var neg = s.charAt(0) === '-';
    if (neg) s = s.slice(1);
    var p = s.split('.');
    p[0] = p[0].replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    return (neg ? '-' : '') + p.join('.');
  }

  function decFor(v, unit) {
    if (v == null || !isFinite(v)) return 0;
    if (String(unit || '').indexOf('/克') >= 0) return 2;
    var s = String(Math.round(v * 100) / 100);
    var i = s.indexOf('.');
    return i < 0 ? 0 : Math.min(2, s.length - i - 1);
  }

  function fmtNum(v, unit) {
    if (v == null || !isFinite(v)) return '—';
    return group(v, decFor(v, unit));
  }

  function fmtPct(v) {
    if (v == null || !isFinite(v)) return '—';
    var a = Math.abs(v);
    if (a < 0.005) return '0.00%';
    return (v > 0 ? '+' : '-') + a.toFixed(2) + '%';
  }

  function fmtSigned(v, unit) {
    if (v == null || !isFinite(v)) return '—';
    var d = decFor(v, unit);
    if (Math.abs(v) < 0.5 * Math.pow(10, -d)) return '0';
    return (v > 0 ? '+' : '-') + group(Math.abs(v), d);
  }

  function trendCls(v) {
    if (v == null || !isFinite(v) || Math.abs(v) < 1e-9) return 'flat';
    return v > 0 ? 'up' : 'down';
  }

  function arrow(v) {
    if (v == null || !isFinite(v) || Math.abs(v) < 1e-9) return '—';
    return v > 0 ? '▲' : '▼';
  }

  function fmtDateFull(t) {
    var d = new Date(t);
    function p2(n) { return n < 10 ? '0' + n : String(n); }
    return d.getUTCFullYear() + '-' + p2(d.getUTCMonth() + 1) + '-' + p2(d.getUTCDate());
  }

  var SRC_SHORT = {
    shfe: '上期所', dce: '大商所', gfex: '广期所', sge: '上金所',
    smm: 'SMM', baiinfo: '百川盈孚', kq81: '矿权资源网', manual: '内部录入'
  };

  function srcShort(id) {
    if (SRC_SHORT[id]) return SRC_SHORT[id];
    return (MAP.source[id] && MAP.source[id].name) || id || '—';
  }

  var FREQ_NAME = { daily: '日频', weekly: '周频', monthly: '月频', manual: '不定期' };
  function freqName(f) { return FREQ_NAME[f] || f || '—'; }

  var TYPE_NAME = { exchange: '交易所 / 官方', agency: '商业机构', media: '行业媒体', manual: '内部录入' };
  function typeName(t) { return TYPE_NAME[t] || t || '—'; }

  var FRESH_NAME = { normal: '正常', stale: '滞后', stopped: '停报' };

  function trustBadge(e) {
    if (!e) return '';
    var t = String(e.trust || 'D').toUpperCase();
    return '<span class="badge badge-' + t.toLowerCase() + '" title="数据可信度 ' + t + '">' +
      esc(t + ' · ' + srcShort(e.sourceId)) + '</span>';
  }

  function freshBadge(f) {
    var k = FRESH_NAME[f] ? f : 'normal';
    return '<span class="fresh fresh-' + k + '" title="数据新鲜度">' + FRESH_NAME[k] + '</span>';
  }

  // 该条序列是否为示例（程序生成）数据
  function demoTag(e) {
    if (!e || e.demo !== true) return '';
    return '<span class="badge badge-demo" title="演示数据，非真实行情">示例</span>';
  }

  function starBtn(id, on) {
    return '<button class="star-btn' + (on ? ' on' : '') + '" data-act="star" data-id="' + esc(id) + '" ' +
      'title="' + (on ? '从自选移除' : '加入自选') + '" aria-label="' + (on ? '取消自选' : '加入自选') + '">' +
      (on ? '★' : '☆') + '</button>';
  }

  /* ------------------------------------------------------------ 本地存储 */

  function getWatch() {
    try {
      var a = JSON.parse(localStorage.getItem(LS_WATCH) || '[]');
      return Array.isArray(a) ? a.filter(function (x) { return typeof x === 'string'; }) : [];
    } catch (e) { return []; }
  }

  function isWatched(id) { return getWatch().indexOf(id) >= 0; }

  function toggleWatch(id) {
    var a = getWatch();
    var i = a.indexOf(id);
    if (i >= 0) a.splice(i, 1); else a.push(id);
    try { localStorage.setItem(LS_WATCH, JSON.stringify(a)); } catch (e) {}
    return i < 0;
  }

  /* -------------------------------------------------------------- 数据层 */

  function loadData() {
    return Promise.all(FILES.map(function (f) {
      return fetch('data/' + f + '.json', { cache: 'no-store' }).then(function (r) {
        if (!r.ok) throw new Error(f + '.json ' + r.status);
        return r.json();
      });
    })).then(function (arr) {
      FILES.forEach(function (f, i) { D[f] = arr[i]; });
    }).catch(function () {
      return loadBundle();
    });
  }

  function loadBundle() {
    return new Promise(function (resolve, reject) {
      function use() {
        var b = window.__MINE_BUNDLE__;
        if (!b) { reject(new Error('数据文件缺失')); return; }
        FILES.forEach(function (f) { D[f] = b[f]; });
        resolve();
      }
      if (window.__MINE_BUNDLE__) { use(); return; }
      var s = document.createElement('script');
      s.src = 'data/bundle.js';
      s.onload = use;
      s.onerror = function () { reject(new Error('无法加载 data/bundle.js')); };
      document.head.appendChild(s);
    });
  }

  function buildMaps() {
    D.categories.forEach(function (c) { MAP.category[c.id] = c; });
    D.varieties.forEach(function (v) { MAP.variety[v.id] = v; });
    D.sources.forEach(function (s) { MAP.source[s.id] = s; });
    D.series.forEach(function (s) { MAP.series[s.id] = s; });
    D.catalog.forEach(function (e) { MAP.cat[e.seriesId] = e; });
  }

  /* -------------------------------------------------------------- 路由 */

  function parseHash() {
    var raw = location.hash.replace(/^#/, '');
    if (!raw) raw = '/';
    var q = {};
    var qi = raw.indexOf('?');
    if (qi >= 0) {
      var qs = raw.slice(qi + 1);
      raw = raw.slice(0, qi);
      qs.split('&').forEach(function (kv) {
        if (!kv) return;
        var i = kv.indexOf('=');
        var k = i < 0 ? kv : kv.slice(0, i);
        var val = i < 0 ? '' : decodeURIComponent(kv.slice(i + 1));
        q[k] = val;
      });
    }
    var parts = raw.split('/').filter(function (p) { return p !== ''; });
    return { name: parts[0] || 'home', arg: parts[1] || null, query: q };
  }

  function route(opts) {
    if (!D.meta) return;
    var keep = opts && opts.keepScroll;
    var y = window.scrollY;
    var loc = parseHash();
    curRoute = loc;

    if (chartObj) { chartObj.destroy(); chartObj = null; }
    pendingChart = null;

    var html;
    switch (loc.name) {
      case 'home': html = pageHome(); break;
      case 'category': html = pageCategory(loc.arg); break;
      case 'variety': html = pageVariety(loc.arg, loc.query); break;
      case 'compare': html = pageCompare(); break;
      case 'watchlist': html = pageWatchlist(); break;
      case 'ranking': html = pageRanking(); break;
      case 'specs': html = pageSpecs(); break;
      case 'about': html = pageAbout(); break;
      default: html = pageNotFound('页面不存在');
    }

    var view = document.getElementById('view');
    view.innerHTML = html;

    afterRender(loc);
    setActiveNav(loc);
    document.title = pageTitle(loc);

    if (keep) window.scrollTo(0, y); else window.scrollTo(0, 0);
  }

  function navigate(hash, keep) {
    if (keep) keepScrollFlag = true;
    if (location.hash === hash) route({ keepScroll: keep });
    else location.hash = hash;
  }

  function routeKeep() { route({ keepScroll: true }); }

  function pageTitle(loc) {
    var base = (D.meta && D.meta.siteName) || '矿产品价格中枢';
    if (loc.name === 'variety' && MAP.variety[loc.arg]) return MAP.variety[loc.arg].name + ' · ' + base;
    if (loc.name === 'category' && MAP.category[loc.arg]) return MAP.category[loc.arg].name + ' · ' + base;
    var n = { home: '行情总览', compare: '多品种对比', watchlist: '我的自选', ranking: '涨跌榜', specs: '口径字典', about: '关于本站' }[loc.name];
    return n ? n + ' · ' + base : base;
  }

  function setActiveNav(loc) {
    var map = {
      home: 'home', category: 'home', variety: 'home',
      compare: 'compare', watchlist: 'watchlist', ranking: 'ranking',
      specs: 'specs', about: 'about'
    };
    var key = map[loc.name] || '';
    document.querySelectorAll('#nav a').forEach(function (a) {
      a.classList.toggle('active', a.getAttribute('data-route') === key);
    });
    var nav = document.getElementById('nav');
    if (nav) nav.classList.remove('open');
  }

  /* ------------------------------------------------------------ 通用片段 */

  function crumb(items) {
    var h = '<div class="crumb">';
    items.forEach(function (it, i) {
      if (i) h += ' <span class="sep">/</span> ';
      h += it[1] ? '<a href="' + it[1] + '">' + esc(it[0]) + '</a>' : '<span>' + esc(it[0]) + '</span>';
    });
    return h + '</div>';
  }

  function ovItem(label, value) {
    return '<div class="ov-item"><span class="ov-label">' + esc(label) + '</span>' +
      '<span class="ov-value">' + value + '</span></div>';
  }

  function stat(label, valueHtml) {
    return '<div class="stat"><div class="stat-label">' + esc(label) + '</div>' +
      '<div class="stat-value">' + valueHtml + '</div></div>';
  }

  function rangeSeg(act, cur, items) {
    var opts = items || [['7', '7天'], ['30', '30天'], ['90', '90天'], ['365', '1年'], ['all', '全部']];
    return '<div class="seg">' + opts.map(function (o) {
      return '<button data-act="' + act + '" data-v="' + o[0] + '"' +
        (cur === o[0] ? ' class="active"' : '') + '>' + o[1] + '</button>';
    }).join('') + '</div>';
  }

  function specShort(s) {
    var sp = s.spec || {};
    var parts = [];
    if (sp.grade) parts.push(sp.grade);
    if (sp.region) parts.push(sp.region);
    if (sp.currency && sp.currency !== 'CNY') parts.push(sp.currency);
    return parts.join(' · ') || s.label || s.id;
  }

  function filterRange(points, range) {
    if (!points || !points.length) return [];
    if (range === 'all') return points.slice();
    var days = parseInt(range, 10);
    if (!isFinite(days)) return points.slice();
    var last = MineChart.toTime(points[points.length - 1][0]);
    var from = last - days * DAY;
    return points.filter(function (p) { return MineChart.toTime(p[0]) >= from; });
  }

  function computeStats(pts, freq) {
    if (!pts || pts.length < 2) return null;
    var vs = pts.map(function (p) { return p[1]; });
    var hi = -Infinity, lo = Infinity, sum = 0;
    vs.forEach(function (v) { if (v > hi) hi = v; if (v < lo) lo = v; sum += v; });
    var first = vs[0], last = vs[vs.length - 1];
    var chgPct = first ? ((last - first) / first) * 100 : 0;

    var rets = [];
    for (var i = 1; i < vs.length; i++) if (vs[i - 1]) rets.push(vs[i] / vs[i - 1] - 1);
    var vol = null;
    if (rets.length > 2) {
      var m = rets.reduce(function (a, b) { return a + b; }, 0) / rets.length;
      var vsum = rets.reduce(function (a, b) { return a + (b - m) * (b - m); }, 0);
      var sd = Math.sqrt(vsum / (rets.length - 1));
      var py = freq === 'weekly' ? 52 : freq === 'monthly' ? 12 : 252;
      vol = sd * Math.sqrt(py) * 100;
    }
    return { hi: hi, lo: lo, avg: sum / vs.length, chgPct: chgPct, vol: vol };
  }

  /* -------------------------------------------------------------- 品种卡 */

  function varCard(v) {
    if (!v) return '';
    var e = MAP.cat[v.defaultSeriesId];
    if (!e) return '';
    var cls = trendCls(e.changePct);
    var nSer = D.series.filter(function (s) { return s.varietyId === v.id; }).length;
    return '<a class="var-card" href="#/variety/' + esc(v.id) + '">' +
      '<div class="top"><span class="nm">' + esc(v.name) + '</span>' +
      '<span class="right">' + (nSer > 1 ? '<span class="tag">' + nSer + ' 口径</span>' : '') +
      trustBadge(e) + starBtn(v.id, isWatched(v.id)) + '</span></div>' +
      '<div class="price-line"><span class="price ' + cls + '">' + fmtNum(e.latest, e.unit) + '</span>' +
      '<span class="u">' + esc(e.unit) + '</span></div>' +
      '<div class="chg ' + cls + '">' + arrow(e.changePct) + ' ' + fmtSigned(e.change, e.unit) +
      '（' + fmtPct(e.changePct) + '）</div>' +
      '<div class="spark" data-spark="' + esc(e.seriesId) + '"></div>' +
      '<div class="foot"><span>' + esc(e.asOf) + '</span>' + freshBadge(e.freshness) + '</div>' +
      '</a>';
  }

  function catCard(c) {
    var items = D.catalog.filter(function (e) { return e.category === c.id; });
    var vs = D.varieties.filter(function (v) { return v.category === c.id; });
    var u = items.filter(function (e) { return e.changePct > 0; }).length;
    var d = items.filter(function (e) { return e.changePct < 0; }).length;
    var movers = items.slice().sort(function (a, b) {
      return Math.abs(b.changePct) - Math.abs(a.changePct);
    }).slice(0, 2);

    var mv = movers.map(function (e) {
      return '<div class="row"><span>' + esc(e.varietyName) + '</span>' +
        '<span class="' + trendCls(e.changePct) + '">' + fmtPct(e.changePct) + '</span></div>';
    }).join('');

    return '<a class="cat-card" href="#/category/' + esc(c.id) + '">' +
      '<div class="cat-top"><span class="cat-icon">' + esc(c.icon || '•') + '</span>' +
      '<span class="cat-name">' + esc(c.name) + '</span></div>' +
      '<div class="cat-desc">' + esc(c.desc || '') + '</div>' +
      '<div class="cat-count"><b>' + vs.length + '</b> 个品种 · ' + items.length + ' 条序列</div>' +
      '<div class="ud"><span class="up">▲ ' + u + '</span><span class="down">▼ ' + d + '</span></div>' +
      '<div class="movers">' + (mv || '<div class="row"><span>暂无</span></div>') + '</div>' +
      '<div class="cat-enter">进入分类 →</div>' +
      '</a>';
  }

  function asideRank(title, list) {
    var body = list.map(function (e, i) {
      return '<a class="aside-row" href="#/variety/' + esc(e.varietyId) + '">' +
        '<span class="rank">' + (i + 1) + '</span>' +
        '<span class="nm">' + esc(e.varietyName) + '</span>' +
        '<span class="num ' + trendCls(e.changePct) + '">' + fmtPct(e.changePct) + '</span>' +
        '</a>';
    }).join('');
    if (!body) body = '<div class="aside-row"><span class="nm">暂无数据</span></div>';
    return '<div class="card aside-card"><div class="aside-head">' + esc(title) + '</div>' +
      '<div class="aside-body">' + body + '</div></div>';
  }

  /* ---------------------------------------------------------------- 首页 */

  function pageHome() {
    var up = 0, down = 0;
    D.catalog.forEach(function (e) {
      if (e.changePct > 0) up++; else if (e.changePct < 0) down++;
    });

    var h = '';
    var demoCount = D.catalog.filter(function (e) { return e.demo === true; }).length;
    var realCount = D.catalog.length - demoCount;
    if (demoCount > 0) {
      if (realCount === 0) {
        h += '<div class="notice"><span>ⓘ</span><div><strong>示例数据：</strong>' +
          '当前价格为程序生成的演示数据，用于验证页面与流程，不代表真实行情。</div></div>';
      } else {
        h += '<div class="notice"><span>ⓘ</span><div><strong>部分示例数据：</strong>' +
          '上期所 6 条铜铝铅锌镍锡与上金所 2 条金银为交易所公开行情（真实）；' +
          '其余 ' + demoCount + ' 条为程序生成的演示数据，卡片上标有「示例」。' +
          '分类页可查看每条序列的来源。</div></div>';
      }
    }

    h += '<div class="overview">' +
      ovItem('监测品种', D.varieties.length + ' 个') +
      ovItem('报价序列', D.catalog.length + ' 条') +
      ovItem('上涨', '<span class="up">' + up + '</span>') +
      ovItem('下跌', '<span class="down">' + down + '</span>') +
      ovItem('数据截至', D.meta ? esc(D.meta.dataAsOf) : '—') +
      ovItem('数据来源', D.sources.length + ' 家') +
      '</div>';

    h += '<div class="section-head"><h2>分类浏览</h2><span class="hint">按矿种分类查看品种与走势</span></div>';
    h += '<div class="cat-grid">';
    D.categories.slice().sort(function (a, b) { return (a.order || 0) - (b.order || 0); })
      .forEach(function (c) { h += catCard(c); });
    h += '</div>';

    var rows = D.varieties.map(function (v) {
      var e = MAP.cat[v.defaultSeriesId];
      return e ? { v: v, e: e } : null;
    }).filter(Boolean);
    rows = sortRows(rows, state.homeSort);

    h += '<div class="section-head"><h2>全部品种速览</h2>' +
      '<span class="hint">点品种名进入详情；多口径品种可在详情页切换</span></div>';
    h += '<div class="home-grid">';

    h += '<div class="card" style="overflow:hidden">' +
      '<div class="toolbar" style="padding:12px 14px 0;margin-bottom:10px">' +
      '<strong style="font-size:13px">最近报价</strong>' +
      '<span class="spacer"></span>' +
      '<select class="sortsel" data-act="home-sort">' + sortOptions(state.homeSort) + '</select>' +
      '</div>' +
      '<div class="table-wrap"><table class="data stack"><thead><tr>' +
      '<th>品种</th><th>最新价</th><th>涨跌</th><th>涨跌幅</th><th>数据截至</th><th>来源</th><th>状态</th>' +
      '</tr></thead><tbody>';

    rows.forEach(function (r) {
      var e = r.e, v = r.v;
      var cls = trendCls(e.changePct);
      h += '<tr>' +
        '<td data-label="品种"><a href="#/variety/' + esc(v.id) + '"><span class="name">' + esc(v.name) + '</span></a>' + demoTag(e) + '</td>' +
        '<td data-label="最新价"><span class="' + cls + '">' + fmtNum(e.latest, e.unit) + '</span>' +
        '<span class="unit">' + esc(e.unit) + '</span></td>' +
        '<td data-label="涨跌" class="' + cls + '">' + fmtSigned(e.change, e.unit) + '</td>' +
        '<td data-label="涨跌幅" class="' + cls + '">' + arrow(e.changePct) + ' ' + fmtPct(e.changePct) + '</td>' +
        '<td data-label="数据截至">' + esc(e.asOf) + '</td>' +
        '<td data-label="来源" style="text-align:left">' + trustBadge(e) + '</td>' +
        '<td data-label="状态" style="text-align:left">' + freshBadge(e.freshness) + '</td>' +
        '</tr>';
    });
    h += '</tbody></table></div></div>';

    var sorted = D.catalog.filter(function (e) {
      return isFinite(e.changePct) && e.freshness !== 'stopped';
    });
    var top = sorted.slice().sort(function (a, b) { return b.changePct - a.changePct; }).slice(0, 5);
    var bot = sorted.slice().sort(function (a, b) { return a.changePct - b.changePct; }).slice(0, 5);

    h += '<div>' + asideRank('涨幅前 5', top) + '<div style="height:14px"></div>' +
      asideRank('跌幅前 5', bot) + '</div>';
    h += '</div>';

    return h;
  }

  function sortOptions(cur) {
    var opts = [
      ['chg-desc', '涨跌幅 高 → 低'],
      ['chg-asc', '涨跌幅 低 → 高'],
      ['name', '品种名称'],
      ['date', '数据截至 新 → 旧']
    ];
    return opts.map(function (o) {
      return '<option value="' + o[0] + '"' + (o[0] === cur ? ' selected' : '') + '>' + o[1] + '</option>';
    }).join('');
  }

  function sortRows(rows, mode) {
    var out = rows.slice();
    if (mode === 'chg-asc') out.sort(function (a, b) { return a.e.changePct - b.e.changePct; });
    else if (mode === 'name') out.sort(function (a, b) { return String(a.v.name).localeCompare(String(b.v.name), 'zh-CN'); });
    else if (mode === 'date') out.sort(function (a, b) { return String(b.e.asOf).localeCompare(String(a.e.asOf)); });
    else out.sort(function (a, b) { return b.e.changePct - a.e.changePct; });
    return out;
  }

  /* ------------------------------------------------------------ 分类页 */

  function pageCategory(id) {
    var c = MAP.category[id];
    if (!c) return pageNotFound('分类不存在');

    var vs = D.varieties.filter(function (v) { return v.category === id; });
    var entries = D.catalog.filter(function (e) { return e.category === id; });
    var u = entries.filter(function (e) { return e.changePct > 0; }).length;
    var d = entries.filter(function (e) { return e.changePct < 0; }).length;

    var h = crumb([['首页', '#/'], [c.name, null]]);
    h += '<div class="page-title"><h1>' + esc(c.name) + '</h1>' +
      '<span class="tag">' + vs.length + ' 个品种</span>' +
      '<span class="tag up">▲ ' + u + '</span><span class="tag down">▼ ' + d + '</span></div>';
    h += '<div class="page-sub">' + esc(c.desc || '') + ' · 共 ' + entries.length + ' 条报价序列</div>';

    if (!vs.length) {
      return h + '<div class="card"><div class="empty"><div class="big">∅</div>该分类下暂无品种</div></div>';
    }

    h += '<div class="var-grid">' + vs.map(varCard).join('') + '</div>';

    /* 本分类全部口径一览 */
    if (entries.length) {
      h += '<div class="section-head"><h2>本分类全部报价序列</h2>' +
        '<span class="hint">同一品种的不同口径分行列出，点击查看该口径走势</span></div>';
      h += '<div class="card table-wrap"><table class="data stack"><thead><tr>' +
        '<th>品种</th><th>口径</th><th>最新价</th><th>涨跌</th><th>涨跌幅</th><th>数据截至</th><th>来源</th><th>状态</th>' +
        '</tr></thead><tbody>';
      entries.forEach(function (e) {
        var cls = trendCls(e.changePct);
        h += '<tr>' +
          '<td data-label="品种"><a href="#/variety/' + esc(e.varietyId) + '?series=' + esc(e.seriesId) + '">' +
          '<span class="name">' + esc(e.varietyName) + '</span></a></td>' +
          '<td data-label="口径" style="text-align:left"><span class="gap-note">' + esc(srcShort(e.sourceId)) +
          ' · ' + esc(seriesLabel(e.seriesId)) + '</span></td>' +
          '<td data-label="最新价" class="' + cls + '">' + fmtNum(e.latest, e.unit) + '<span class="unit">' + esc(e.unit) + '</span></td>' +
          '<td data-label="涨跌" class="' + cls + '">' + fmtSigned(e.change, e.unit) + '</td>' +
          '<td data-label="涨跌幅" class="' + cls + '">' + arrow(e.changePct) + ' ' + fmtPct(e.changePct) + '</td>' +
          '<td data-label="数据截至">' + esc(e.asOf) + '</td>' +
          '<td data-label="来源" style="text-align:left">' + trustBadge(e) + '</td>' +
          '<td data-label="状态" style="text-align:left">' + freshBadge(e.freshness) + '</td>' +
          '</tr>';
      });
      h += '</tbody></table></div>';
    }
    return h;
  }

  /* 序列的简短口径描述：优先标签，其次 spec 拼接 */
  function seriesLabel(sid) {
    var s = MAP.series[sid];
    if (!s) return '—';
    if (s.label) return s.label;
    var sp = s.spec || {};
    return [sp.grade, sp.region].filter(Boolean).join(' · ') || '—';
  }

  /* ------------------------------------------------------------ 详情页 */

  function pageVariety(id, query) {
    var v = MAP.variety[id];
    if (!v) return pageNotFound('品种不存在');

    var list = D.series.filter(function (s) { return s.varietyId === id; });
    if (!list.length) return pageNotFound('该品种暂无报价序列');

    var sid = v.defaultSeriesId;
    if (query && query.series && MAP.series[query.series] && MAP.series[query.series].varietyId === id) {
      sid = query.series;
    }
    var s = MAP.series[sid];
    var e = MAP.cat[sid];
    if (!s || !e) return pageNotFound('序列数据缺失');

    var cat = MAP.category[v.category];
    var pts = filterRange(s.points, state.range);
    var st = computeStats(pts, s.freq);
    var gaps = MineChart.findGaps(pts, s.freq);
    var cls = trendCls(e.changePct);

    var h = crumb([['首页', '#/'], [cat ? cat.name : '分类', '#/category/' + v.category], [v.name, null]]);

    h += '<div class="page-title"><h1>' + esc(v.name) + '</h1>';
    if (cat) h += '<a class="tag" href="#/category/' + esc(cat.id) + '">' + esc(cat.name) + '</a>';
    h += v.hasFutures
      ? '<span class="tag" title="有期货或连续撮合交易，可做到近实时">有期货</span>'
      : '<span class="tag" title="无期货，价格依赖机构或媒体报价">无期货</span>';
    h += '<span style="margin-left:auto"></span>';
    h += '<span class="gap-note">' + (isWatched(v.id) ? '已在自选' : '未加入自选') + '</span>';
    h += '</div>';
    h += '<div class="page-sub">' + esc(v.description || s.label || '') + '</div>';

    h += '<div class="detail-top">';

    /* --- 左列 --- */
    h += '<div class="detail-col">';

    h += '<div class="card" style="padding:20px">' +
      '<div class="price-main">' +
      '<span class="price-big ' + cls + '">' + fmtNum(e.latest, e.unit) + '</span>' +
      '<span class="price-unit">' + esc(e.unit) + '</span>' +
      '<span class="price-change ' + cls + '">' + arrow(e.changePct) + ' ' +
      fmtSigned(e.change, e.unit) + '（' + fmtPct(e.changePct) + '）</span>' +
      '</div>' +
      '<div class="price-meta">' +
      '<span>数据截至 <b>' + esc(e.asOf) + '</b></span>' +
      '<span>' + trustBadge(e) + '</span>' +
      freshBadge(e.freshness) +
      demoTag(e) +
      '<span style="margin-left:auto"></span>' +
      starBtn(v.id, isWatched(v.id)) +
      '</div>' +
      '</div>';

    if (list.length > 1) {
      h += '<div class="card" style="padding:12px 14px">' +
        '<div style="font-size:12px;color:var(--text-2);margin-bottom:8px">口径 / 来源切换（同一品种的不同口径分别成线，不做合并）</div>' +
        '<div class="tabs">' + list.map(function (x) {
          var on = x.id === sid;
          return '<button class="tab' + (on ? ' active' : '') + '" data-act="series" data-id="' + esc(x.id) + '">' +
            esc(srcShort(x.sourceId)) + ' · ' + esc(specShort(x)) + '</button>';
        }).join('') + '</div></div>';
    }

    h += '<div class="card chart-card">' +
      '<div class="chart-head">' + rangeSeg('range', state.range) +
      '<span class="gap-note" style="margin-left:auto">' +
      (e.demo === false
        ? '按交易日排列，周末与法定休市不算作缺口'
        : (gaps.length
          ? '⚠ 区间内 ' + gaps.length + ' 处缺口，最长约 ' +
            Math.max.apply(null, gaps.map(function (g) { return g.missing; })) + ' 天，已断开不连线'
          : '区间内数据连续')) +
      '</span></div>' +
      '<div class="chart-host" id="chart"></div>' +
      '</div>';

    if (st) {
      h += '<div class="stats-grid">' +
        stat('区间最高', fmtNum(st.hi, e.unit)) +
        stat('区间最低', fmtNum(st.lo, e.unit)) +
        stat('区间均价', fmtNum(st.avg, e.unit)) +
        stat('区间涨跌', '<span class="' + trendCls(st.chgPct) + '">' + fmtPct(st.chgPct) + '</span>') +
        stat('年化波动率', st.vol == null ? '—' : st.vol.toFixed(1) + '%') +
        '</div>';
    } else {
      h += '<div class="card"><div class="empty">所选区间内数据点不足，无法统计</div></div>';
    }

    /* 数据表 */
    var showN = Math.min(30, pts.length);
    var rowsHtml = '';
    for (var i = pts.length - 1; i >= Math.max(0, pts.length - showN); i--) {
      var cur = pts[i];
      var prev = i > 0 ? pts[i - 1][1] : null;
      var ch = prev == null ? null : cur[1] - prev;
      var cp = prev ? (ch / prev) * 100 : null;
      rowsHtml += '<tr>' +
        '<td data-label="日期">' + esc(cur[0]) + '</td>' +
        '<td data-label="价格">' + fmtNum(cur[1], e.unit) + '</td>' +
        '<td data-label="涨跌" class="' + trendCls(ch) + '">' + (ch == null ? '—' : fmtSigned(ch, e.unit)) + '</td>' +
        '<td data-label="涨跌幅" class="' + trendCls(cp) + '">' + (cp == null ? '—' : arrow(cp) + ' ' + fmtPct(cp)) + '</td>' +
        '</tr>';
    }

    h += '<div class="card" style="overflow:hidden">' +
      '<div class="toolbar" style="padding:12px 14px 0;margin-bottom:10px">' +
      '<strong style="font-size:13px">历史数据</strong>' +
      '<span class="gap-note">显示最近 ' + showN + ' 条 / 共 ' + pts.length + ' 条</span>' +
      '<span class="spacer"></span>' +
      '<button class="btn btn-sm" data-act="csv" data-id="' + esc(s.id) + '">导出 CSV</button>' +
      '</div>' +
      '<div class="table-wrap"><table class="data stack"><thead><tr>' +
      '<th>日期</th><th>价格</th><th>涨跌</th><th>涨跌幅</th>' +
      '</tr></thead><tbody>' + rowsHtml + '</tbody></table></div></div>';

    h += '</div>';

    /* --- 右列 --- */
    h += '<div class="detail-col">';
    h += '<div class="card side-card"><h3>口径说明</h3>' + specTable(s) + '</div>';
    h += '<div class="card side-card"><h3>数据来源</h3>' + sourceCard(s, e) + '</div>';
    h += '<div class="card side-card"><h3>相关品种</h3>' + relatedHtml(v) + '</div>';
    h += '</div>';

    h += '</div>';

    pendingChart = {
      kind: 'detail',
      series: [{ points: pts, label: v.name, demo: e.demo === true, color: trendColor(e.changePct) }],
      freq: s.freq,
      unit: e.unit,
      minDecimals: decFor(e.latest, e.unit)
    };

    return h;
  }

  function trendColor(pct) {
    if (pct > 0) return MineChart.css('--up');
    if (pct < 0) return MineChart.css('--down');
    return MineChart.css('--accent');
  }

  function specTable(s) {
    var sp = s.spec || {};
    var names = { grade: '品位/牌号', tax: '税费', region: '地区', delivery: '交货', currency: '币种' };
    var items = '';
    Object.keys(names).forEach(function (k) {
      if (sp[k]) {
        items += '<div class="spec-item"><span class="k">' + names[k] + '</span>' +
          '<span class="v">' + esc(sp[k]) + '</span></div>';
      }
    });
    items += '<div class="spec-item"><span class="k">计价单位</span><span class="v">' + esc(s.unit) + '</span></div>';
    items += '<div class="spec-item"><span class="k">更新频率</span><span class="v">' + esc(freqName(s.freq)) + '</span></div>';
    items += '<div class="spec-item"><span class="k">数据点</span><span class="v">' + s.points.length + ' 个</span></div>';
    items += '<div class="spec-item"><span class="k">最新更新</span><span class="v">' + esc(s.updatedAt) + '</span></div>';
    return '<div class="spec-list" style="grid-template-columns:1fr">' + items + '</div>' +
      '<div class="gap-note" style="margin-top:10px">' + esc(s.label || '') + '</div>';
  }

  function sourceCard(s, e) {
    var src = MAP.source[s.sourceId] || {};
    return '<div class="spec-list" style="grid-template-columns:1fr">' +
      '<div class="spec-item"><span class="k">来源</span><span class="v">' + esc(src.name || s.sourceId) + '</span></div>' +
      '<div class="spec-item"><span class="k">可信度</span><span class="v">' + trustBadge(e) + '</span></div>' +
      '<div class="spec-item"><span class="k">类型</span><span class="v">' + esc(typeName(src.type)) + '</span></div>' +
      '</div>' +
      (src.note ? '<div class="gap-note" style="margin-top:8px">' + esc(src.note) + '</div>' : '') +
      (src.url ? '<div style="margin-top:8px"><a class="btn btn-sm" href="' + esc(src.url) +
        '" target="_blank" rel="noopener">访问来源 ↗</a></div>' : '');
  }

  function relatedHtml(v) {
    var list = D.varieties.filter(function (x) {
      return x.category === v.category && x.id !== v.id;
    }).slice(0, 5);
    if (!list.length) return '<div class="gap-note">该分类下暂无其他品种</div>';
    return list.map(function (x) {
      var e = MAP.cat[x.defaultSeriesId];
      return '<a class="aside-row" href="#/variety/' + esc(x.id) + '" style="padding-left:0;padding-right:0">' +
        '<span class="nm">' + esc(x.name) + '</span>' +
        (e ? '<span class="num ' + trendCls(e.changePct) + '">' + fmtPct(e.changePct) + '</span>' : '') +
        '</a>';
    }).join('');
  }

  /* ------------------------------------------------------------ 对比页 */

  function pageCompare() {
    var ids = state.cmpIds.filter(function (id) { return MAP.variety[id]; });

    var h = '<div class="page-title"><h1>多品种对比</h1><span class="tag">最多 6 个</span></div>';
    h += '<div class="page-sub">统一归一到 100（区间首个数据点 = 100）。不同品种单位不同，只看形状与相对幅度，不比较绝对价格。</div>';

    h += '<div class="card" style="padding:14px;margin-bottom:14px">' +
      '<div class="gap-note" style="margin-bottom:8px">选择品种</div><div class="picker">';
    D.varieties.forEach(function (v) {
      var on = ids.indexOf(v.id) >= 0;
      var dis = !on && ids.length >= 6;
      h += '<button class="pick' + (on ? ' on' : '') + '" data-act="pick" data-id="' + esc(v.id) + '"' +
        (dis ? ' disabled' : '') + '>' + esc(v.name) + '</button>';
    });
    h += '</div><div style="display:flex;gap:10px;align-items:center;margin-top:12px;flex-wrap:wrap">' +
      rangeSeg('cmp-range', state.cmpRange, [['30', '30天'], ['90', '90天'], ['365', '1年'], ['all', '全部']]) +
      '<span class="spacer" style="margin-left:auto"></span>' +
      '<button class="btn btn-sm" data-act="cmp-clear">清空</button>' +
      '</div></div>';

    if (ids.length < 2) {
      return h + '<div class="card"><div class="empty"><div class="big">⇅</div>' +
        '请至少选择 2 个品种进行对比</div></div>';
    }

    var cfgSeries = [];
    ids.forEach(function (id, i) {
      var v = MAP.variety[id];
      var s = MAP.series[v.defaultSeriesId];
      if (!s) return;
      var pts = filterRange(s.points, state.cmpRange);
      if (pts.length < 2) return;
      cfgSeries.push({
        points: pts,
        label: v.name,
        color: MineChart.palette[i % MineChart.palette.length]
      });
    });

    h += '<div class="card chart-card">' +
      '<div class="chart-head"><strong style="font-size:13px">归一化走势（base = 100）</strong></div>' +
      '<div class="chart-host" id="chart"></div>' +
      '<div class="legend">' + cfgSeries.map(function (s) {
        return '<span><i style="background:' + s.color + '"></i>' + esc(s.label) + '</span>';
      }).join('') + '</div></div>';

    h += '<div class="section-head"><h2>区间表现</h2><span class="hint">按所选区间计算</span></div>';
    h += '<div class="card table-wrap"><table class="data stack"><thead><tr>' +
      '<th>品种</th><th>区间涨跌幅</th><th>最新价</th><th>单位</th></tr></thead><tbody>';

    ids.forEach(function (id) {
      var v = MAP.variety[id];
      var s = MAP.series[v.defaultSeriesId];
      var e = MAP.cat[v.defaultSeriesId];
      var pts = s ? filterRange(s.points, state.cmpRange) : [];
      var pct = pts.length > 1 && pts[0][1] ? (pts[pts.length - 1][1] / pts[0][1] - 1) * 100 : null;
      h += '<tr>' +
        '<td data-label="品种"><a href="#/variety/' + esc(id) + '"><span class="name">' + esc(v.name) + '</span></a></td>' +
        '<td data-label="区间涨跌幅" class="' + trendCls(pct) + '">' + (pct == null ? '—' : fmtPct(pct)) + '</td>' +
        '<td data-label="最新价">' + (e ? fmtNum(e.latest, e.unit) : '—') + '</td>' +
        '<td data-label="单位" style="text-align:left">' + (e ? esc(e.unit) : '—') + '</td>' +
        '</tr>';
    });
    h += '</tbody></table></div>';

    if (cfgSeries.length >= 2) {
      pendingChart = { kind: 'compare', series: cfgSeries };
    }

    return h;
  }

  /* ------------------------------------------------------------ 自选页 */

  function pageWatchlist() {
    var ids = getWatch().filter(function (id) { return MAP.variety[id]; });

    var h = '<div class="page-title"><h1>我的自选</h1><span class="tag">' + ids.length + ' 个品种</span></div>';
    h += '<div class="page-sub">自选保存在本机浏览器（localStorage），不上传、不同步。</div>';

    if (!ids.length) {
      return h + '<div class="card"><div class="empty"><div class="big">☆</div>' +
        '还没有自选品种<br><a href="#/">去首页挑选</a></div></div>';
    }

    h += '<div class="var-grid">' + ids.map(function (id) { return varCard(MAP.variety[id]); }).join('') + '</div>';
    return h;
  }

  /* ------------------------------------------------------------ 涨跌榜 */

  function pageRanking() {
    var tab = state.rankTab;
    var list = D.catalog.slice().filter(function (e) {
      return isFinite(e.changePct) && e.freshness !== 'stopped';
    });
    list.sort(function (a, b) {
      return tab === 'down' ? a.changePct - b.changePct : b.changePct - a.changePct;
    });

    var h = '<div class="page-title"><h1>涨跌榜</h1><span class="tag">按最新一期涨跌幅</span></div>';
    h += '<div class="page-sub">同一品种的不同口径分别参与排名，不做合并。已排除已停报的序列，避免用过期价格排名。</div>';

    h += '<div class="tabs" style="margin-bottom:14px">' +
      '<button class="tab' + (tab === 'up' ? ' active' : '') + '" data-act="rank-tab" data-v="up">涨幅榜</button>' +
      '<button class="tab' + (tab === 'down' ? ' active' : '') + '" data-act="rank-tab" data-v="down">跌幅榜</button>' +
      '</div>';

    h += '<div class="card table-wrap"><table class="data stack"><thead><tr>' +
      '<th>#</th><th>品种</th><th>口径</th><th>最新价</th><th>涨跌</th><th>涨跌幅</th><th>数据截至</th><th>来源</th><th>状态</th>' +
      '</tr></thead><tbody>';

    list.forEach(function (e, i) {
      var cls = trendCls(e.changePct);
      h += '<tr>' +
        '<td data-label="#" style="text-align:left;color:var(--text-3)">' + (i + 1) + '</td>' +
        '<td data-label="品种"><a href="#/variety/' + esc(e.varietyId) + '"><span class="name">' + esc(e.varietyName) + '</span></a>' + demoTag(e) + '</td>' +
        '<td data-label="口径" style="text-align:left"><span class="gap-note">' + esc(srcShort(e.sourceId)) + '</span></td>' +
        '<td data-label="最新价" class="' + cls + '">' + fmtNum(e.latest, e.unit) + '<span class="unit">' + esc(e.unit) + '</span></td>' +
        '<td data-label="涨跌" class="' + cls + '">' + fmtSigned(e.change, e.unit) + '</td>' +
        '<td data-label="涨跌幅" class="' + cls + '">' + arrow(e.changePct) + ' ' + fmtPct(e.changePct) + '</td>' +
        '<td data-label="数据截至">' + esc(e.asOf) + '</td>' +
        '<td data-label="来源" style="text-align:left">' + trustBadge(e) + '</td>' +
        '<td data-label="状态" style="text-align:left">' + freshBadge(e.freshness) + '</td>' +
        '</tr>';
    });
    h += '</tbody></table></div>';
    return h;
  }

  /* ------------------------------------------------------------ 口径字典 */

  function pageSpecs() {
    var h = '<div class="page-title"><h1>口径字典</h1><span class="tag">' + D.series.length + ' 条序列</span></div>';
    h += '<div class="page-sub">一条序列 = 一个品种 + 一个口径 + 一个来源。不同口径或不同来源的数据永远不合并成一条线。</div>';

    h += '<div class="card table-wrap"><table class="data stack"><thead><tr>' +
      '<th>品种</th><th>口径描述</th><th>单位</th><th>频率</th><th>来源</th><th>可信度</th><th>数据点</th><th>最新</th><th>数据性质</th>' +
      '</tr></thead><tbody>';

    D.series.forEach(function (s) {
      var v = MAP.variety[s.varietyId] || {};
      var e = MAP.cat[s.id];
      h += '<tr>' +
        '<td data-label="品种"><a href="#/variety/' + esc(s.varietyId) + '?series=' + esc(s.id) + '">' +
        '<span class="name">' + esc(v.name || s.varietyId) + '</span></a></td>' +
        '<td data-label="口径" style="text-align:left">' + esc(s.label || '') + '</td>' +
        '<td data-label="单位" style="text-align:left">' + esc(s.unit) + '</td>' +
        '<td data-label="频率" style="text-align:left">' + esc(freqName(s.freq)) + '</td>' +
        '<td data-label="来源" style="text-align:left">' + esc(srcShort(s.sourceId)) + '</td>' +
        '<td data-label="可信度" style="text-align:left">' + (e ? trustBadge(e) : '—') + '</td>' +
        '<td data-label="数据点">' + s.points.length + '</td>' +
        '<td data-label="最新">' + esc(s.updatedAt) + '</td>' +
        '<td data-label="数据性质" style="text-align:left">' +
          (e && e.demo === true ? demoTag(e) : '<span class="muted">交易所行情</span>') + '</td>' +
        '</tr>';
    });
    h += '</tbody></table></div>';
    return h;
  }

  /* -------------------------------------------------------------- 关于 */

  function pageAbout() {
    var h = '<div class="page-title"><h1>关于本站</h1></div>';
    h += '<div class="page-sub">金属与非金属矿产品价格走势看板 · 数据说明与使用约定</div>';

    h += '<div class="detail-top"><div class="detail-col">';

    h += '<div class="card side-card"><h3>这个站点解决什么问题</h3>' +
      '<p style="margin:0 0 10px;font-size:13px;line-height:1.8">' +
      '矿产品价格的三个麻烦：<b>频率不齐</b>（有的秒级、有的一月一次）、<b>口径不一</b>（品位、含税、交货地各不相同）、' +
      '<b>可信度参差</b>（交易所官方、商业机构、行业媒体、内部询价差别很大）。' +
      '本站把不同来源的报价放进同一套数据结构里，用统一的展示规则呈现，而不是把它们混成一条看似连续的价格曲线。</p>' +
      '<p style="margin:0;font-size:13px;line-height:1.8">三条硬规则：一条线只对应一个「品种 + 口径 + 来源」；' +
      '缺失的数据不补点、不插值，图上直接断开；每条价格都标注数据截止时间和来源可信度。</p>' +
      '</div>';

    h += '<div class="card side-card"><h3>数据模型</h3>' +
      '<div class="table-wrap"><table class="data"><thead><tr><th>实体</th><th>说明</th></tr></thead><tbody>' +
      '<tr><td style="text-align:left"><b>品种</b> varieties</td><td style="text-align:left">矿种本身，如铜、萤石</td></tr>' +
      '<tr><td style="text-align:left"><b>来源</b> sources</td><td style="text-align:left">交易所 / 机构 / 媒体 / 内部录入</td></tr>' +
      '<tr><td style="text-align:left"><b>口径</b> spec</td><td style="text-align:left">品位、税费、地区、交货方式、币种</td></tr>' +
      '<tr><td style="text-align:left"><b>序列</b> series</td><td style="text-align:left">品种 + 口径 + 来源 的一条时间序列</td></tr>' +
      '</tbody></table></div>' +
      '<div class="gap-note" style="margin-top:8px">走势线的唯一键是三元组 (品种, 口径, 来源)，任何一条价格都不允许跨口径合并。</div>' +
      '</div>';

    h += '<div class="card side-card"><h3>可信度分级</h3>' +
      '<div class="spec-list" style="grid-template-columns:1fr">' +
      '<div class="spec-item"><span class="v"><span class="badge badge-a">A</span></span><span>交易所、官方机构发布</span></div>' +
      '<div class="spec-item"><span class="v"><span class="badge badge-b">B</span></span><span>商业报价机构（如 SMM、百川盈孚）</span></div>' +
      '<div class="spec-item"><span class="v"><span class="badge badge-c">C</span></span><span>行业媒体转载或公开报价</span></div>' +
      '<div class="spec-item"><span class="v"><span class="badge badge-d">D</span></span><span>内部询价、人工录入，仅供参考</span></div>' +
      '</div></div>';

    h += '<div class="card side-card"><h3>新鲜度判定</h3>' +
      '<div class="table-wrap"><table class="data"><thead><tr><th>频率</th><th>正常</th><th>滞后</th><th>停报</th></tr></thead><tbody>' +
      '<tr><td style="text-align:left">日频</td><td>≤1 个工作日</td><td>2–5 天</td><td>&gt;5 天</td></tr>' +
      '<tr><td style="text-align:left">周频</td><td>≤7 天</td><td>8–21 天</td><td>&gt;21 天</td></tr>' +
      '<tr><td style="text-align:left">月频</td><td>≤31 天</td><td>32–62 天</td><td>&gt;62 天</td></tr>' +
      '</tbody></table></div>' +
      '<div class="gap-note" style="margin-top:8px">滞后与停报的品种在列表和详情页都会显式标注，避免把旧价格当成今天的最新价。</div>' +
      '</div>';

    h += '</div><div class="detail-col">';

    h += '<div class="card side-card"><h3>如何接入真实数据</h3>' +
      '<div style="font-size:13px;line-height:1.85">' +
      '<div>1. 按 <code class="mono">数据模型</code> 生成 6 个 JSON，放入 <code class="mono">data/</code> 目录：' +
      '<code class="mono">meta / categories / varieties / sources / series / catalog</code>。</div>' +
      '<div>2. <code class="mono">series.json</code> 的 <code class="mono">points</code> 为 <code class="mono">[日期, 价格]</code>，按日期升序；缺数据的日期直接不写，不要补点。</div>' +
      '<div>3. 删掉 <code class="mono">meta.json</code> 里的 <code class="mono">demoData</code> 字段，站点的「示例数据」标记自动消失。</div>' +
      '<div>4. 数据量大时，删掉 <code class="mono">data/bundle.js</code>，并在本地起一个静态服务器（file:// 无法 fetch 本地 JSON）。</div>' +
      '</div></div>';

    h += '<div class="card side-card"><h3>免责声明</h3>' +
      '<p style="margin:0;font-size:13px;line-height:1.8">' +
      (D.meta && D.meta.disclaimer ? esc(D.meta.disclaimer) : '价格口径以各来源为准，本站不构成任何交易或投资建议。') +
      '</p><div class="gap-note" style="margin-top:10px">版本 ' +
      (D.meta ? esc(D.meta.version) : '1.2.0') + ' · 生成于 ' + (D.meta ? esc(D.meta.generatedAt) : '—') + '</div></div>';

    h += '<div class="card side-card"><h3>快捷入口</h3>' +
      '<div class="spec-list" style="grid-template-columns:1fr">' +
      '<div class="spec-item"><a href="#/ranking">→ 涨跌榜</a></div>' +
      '<div class="spec-item"><a href="#/compare">→ 多品种对比</a></div>' +
      '<div class="spec-item"><a href="#/specs">→ 口径字典</a></div>' +
      '<div class="spec-item"><a href="#/watchlist">→ 我的自选</a></div>' +
      '</div></div>';

    h += '</div></div>';
    return h;
  }

  function pageNotFound(msg) {
    return '<div class="card"><div class="empty"><div class="big">∅</div>' +
      esc(msg || '页面不存在') + '<br><a href="#/">返回首页</a></div></div>';
  }

  /* ------------------------------------------------------------ 渲染后处理 */

  function afterRender(loc) {
    document.querySelectorAll('[data-spark]').forEach(function (host) {
      var e = MAP.cat[host.getAttribute('data-spark')];
      if (!e || !e.spark) return;
      var color = trendColor(e.changePct);
      MineChart.spark(host, e.spark, color);
    });

    if (!pendingChart) return;
    var host = document.getElementById('chart');
    if (!host) { pendingChart = null; return; }

    var cfg = { series: pendingChart.series };

    if (pendingChart.kind === 'compare') {
      cfg.normalize = true;
      cfg.area = false;
      cfg.height = 360;
      cfg.freq = 'daily';
      cfg.minDecimals = 0;
      cfg.maxDecimals = 0;
      cfg.tipRender = function (t, rows) {
        var html = '<div class="tt-date">' + fmtDateFull(t) + '</div>';
        rows.forEach(function (r) {
          html += '<div class="tt-row"><span class="tt-dot" style="background:' + r.color + '"></span>' +
            '<span class="tt-k">' + esc(r.label) + '</span>' +
            '<span class="tt-v">' + group(r.point.v, 1) + ' · ' + fmtPct(r.point.v - 100) + '</span></div>';
        });
        return html;
      };
    } else {
      cfg.area = true;
      cfg.height = 320;
      cfg.freq = pendingChart.freq;
      cfg.unit = pendingChart.unit;
      cfg.minDecimals = pendingChart.minDecimals || 0;
    }

    chartObj = MineChart.line(host, cfg);
    pendingChart = null;
  }

  /* -------------------------------------------------------------- 事件 */

  function onClick(ev) {
    var t = ev.target;
    var btn = t && t.closest ? t.closest('[data-act]') : null;
    if (!btn) return;
    var act = btn.getAttribute('data-act');

    if (act === 'star') {
      ev.preventDefault();
      ev.stopPropagation();
      toggleWatch(btn.getAttribute('data-id'));
      routeKeep();
      return;
    }

    if (act === 'series') {
      var sid = btn.getAttribute('data-id');
      var s = MAP.series[sid];
      if (!s) return;
      navigate('#/variety/' + s.varietyId + '?series=' + encodeURIComponent(sid), true);
      return;
    }

    if (act === 'range') {
      state.range = btn.getAttribute('data-v');
      routeKeep();
      return;
    }

    if (act === 'cmp-range') {
      state.cmpRange = btn.getAttribute('data-v');
      routeKeep();
      return;
    }

    if (act === 'pick') {
      var id = btn.getAttribute('data-id');
      var i = state.cmpIds.indexOf(id);
      if (i >= 0) state.cmpIds.splice(i, 1);
      else if (state.cmpIds.length < 6) state.cmpIds.push(id);
      routeKeep();
      return;
    }

    if (act === 'cmp-clear') {
      state.cmpIds = [];
      routeKeep();
      return;
    }

    if (act === 'rank-tab') {
      state.rankTab = btn.getAttribute('data-v');
      routeKeep();
      return;
    }

    if (act === 'csv') {
      exportCSV(btn.getAttribute('data-id'));
      return;
    }
  }

  function onChange(ev) {
    var t = ev.target;
    if (!t || !t.getAttribute) return;
    if (t.getAttribute('data-act') === 'home-sort') {
      state.homeSort = t.value;
      routeKeep();
    }
  }

  function exportCSV(sid) {
    var s = MAP.series[sid];
    if (!s) return;
    var v = MAP.variety[s.varietyId] || {};
    var lines = ['日期,价格,单位,品种,口径'];
    s.points.forEach(function (p) {
      lines.push([p[0], p[1], s.unit, v.name || '', String(s.label || '').replace(/,/g, '；')].join(','));
    });
    var blob = new Blob(['\ufeff' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = (v.name || s.varietyId) + '_' + s.id + '.csv';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 3000);
  }

  /* ------------------------------------------------------------ 主题/搜索 */

  function applyTheme(t) {
    var dark = t === 'dark';
    document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light');
    var b = document.getElementById('themeBtn');
    if (b) b.textContent = dark ? '☀' : '◐';
  }

  function toggleTheme() {
    var cur = document.documentElement.getAttribute('data-theme') === 'dark';
    var next = cur ? 'light' : 'dark';
    applyTheme(next);
    try { localStorage.setItem(LS_THEME, next); } catch (e) {}
    if (D.meta) routeKeep();
  }

  function bindSearch() {
    var q = document.getElementById('q');
    var box = document.getElementById('qres');
    if (!q || !box) return;

    q.addEventListener('input', function () {
      var kw = q.value.trim().toLowerCase();
      if (!kw) { box.hidden = true; box.innerHTML = ''; return; }
      var hits = D.varieties.filter(function (x) {
        if (String(x.name).toLowerCase().indexOf(kw) >= 0) return true;
        if (String(x.id).indexOf(kw) >= 0) return true;
        return (x.aliases || []).some(function (a) {
          return String(a).toLowerCase().indexOf(kw) >= 0;
        });
      }).slice(0, 8);

      if (!hits.length) {
        box.innerHTML = '<div class="search-empty">未找到匹配品种</div>';
        box.hidden = false;
        return;
      }
      box.innerHTML = hits.map(function (x) {
        var c = MAP.category[x.category] || {};
        return '<button data-goto="' + esc(x.id) + '"><span class="sr-name">' + esc(x.name) + '</span>' +
          '<span class="sr-meta">' + esc(c.name || '') + '</span></button>';
      }).join('');
      box.hidden = false;
    });

    box.addEventListener('click', function (ev) {
      var b = ev.target.closest('[data-goto]');
      if (!b) return;
      q.value = '';
      box.hidden = true;
      navigate('#/variety/' + b.getAttribute('data-goto'));
    });

    document.addEventListener('click', function (ev) {
      if (!ev.target.closest || !ev.target.closest('#search')) box.hidden = true;
    });

    q.addEventListener('keydown', function (ev) {
      if (ev.key === 'Enter') {
        var first = box.querySelector('[data-goto]');
        if (first) first.click();
      } else if (ev.key === 'Escape') {
        box.hidden = true;
      }
    });
  }

  /* ---------------------------------------------------------------- 启动 */

  function updateChrome() {
    var ds = document.getElementById('datestamp');
    if (ds && D.meta) ds.innerHTML = '截至 <b>' + esc(D.meta.dataAsOf) + '</b>';
    var flag = document.getElementById('demoFlag');
    if (flag) flag.hidden = !(D.meta && D.meta.demoData);
    var ver = document.getElementById('ver');
    if (ver && D.meta) ver.textContent = D.meta.version;
  }

  function init() {
    var saved = 'light';
    try { saved = localStorage.getItem(LS_THEME) || 'light'; } catch (e) {}
    /* 支持 #/xxx?theme=dark 直接以深色打开（便于分享/截图） */
    var forced = (location.hash.match(/[?&]theme=(dark|light)/) || [])[1];
    applyTheme(forced || saved);

    document.getElementById('themeBtn').addEventListener('click', toggleTheme);
    document.getElementById('menuBtn').addEventListener('click', function (ev) {
      ev.stopPropagation();
      document.getElementById('nav').classList.toggle('open');
    });

    document.addEventListener('click', onClick);
    document.addEventListener('change', onChange);
    window.addEventListener('hashchange', function () {
      var k = keepScrollFlag;
      keepScrollFlag = false;
      route({ keepScroll: k });
    });

    bindSearch();

    loadData().then(function () {
      buildMaps();
      updateChrome();
      route();
    }).catch(function (err) {
      document.getElementById('view').innerHTML =
        '<div class="card"><div class="empty"><div class="big">!</div>数据加载失败<br>' +
        '<span class="gap-note">' + esc(err && err.message ? err.message : String(err)) + '</span><br>' +
        '<span class="gap-note">请确认 data/ 目录下 6 个 JSON 或 data/bundle.js 存在。</span></div></div>';
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
}());
