/* 手写 SVG 图表模块
 * 功能：折线（数据缺口处断线 + 虚线连接）、面积渐变、悬停十字光标、
 *       多序列对比、归一化（base=100）、迷你走势 spark。
 * 无外部依赖，经典 script 引入，挂在 window.MineChart。
 */
(function (global) {
  'use strict';

  var NS = 'http://www.w3.org/2000/svg';
  var uid = 0;
  /* 多序列配色刻意避开红/绿：红绿在本站专用于涨跌语义 */
  var PALETTE = ['#2563EB', '#D97706', '#7C3AED', '#0891B2', '#DB2777', '#65A30D', '#475569', '#B45309'];
  var DAY = 86400000;

  /* ------------------------------------------------------------- 基础工具 */

  function el(name, attrs) {
    var n = document.createElementNS(NS, name);
    if (attrs) {
      for (var k in attrs) {
        if (Object.prototype.hasOwnProperty.call(attrs, k)) {
          var v = attrs[k];
          if (v !== null && v !== undefined) n.setAttribute(k, String(v));
        }
      }
    }
    return n;
  }

  function toTime(s) {
    var str = String(s);
    var head = str.slice(0, 10).split('-');
    var t = Date.UTC(parseInt(head[0], 10), parseInt(head[1], 10) - 1, parseInt(head[2], 10));
    /* 支持 "YYYY-MM-DD HH:MM"（日内分时） */
    var m = str.match(/[ T](\d{1,2}):(\d{2})/);
    if (m) t += parseInt(m[1], 10) * 3600000 + parseInt(m[2], 10) * 60000;
    return t;
  }

  function isIntradayKey(s) { return /[ T]\d{1,2}:\d{2}/.test(String(s)); }

  function pad2(n) { return n < 10 ? '0' + n : String(n); }

  function fmtDate(t, mode) {
    var d = new Date(t);
    var y = d.getUTCFullYear(), m = d.getUTCMonth() + 1, dy = d.getUTCDate();
    var hh = d.getUTCHours(), mi = d.getUTCMinutes();
    if (mode === 'ym') return String(y).slice(2) + '-' + pad2(m);
    if (mode === 'full') return y + '-' + pad2(m) + '-' + pad2(dy);
    if (mode === 'hm') return pad2(hh) + ':' + pad2(mi);
    return pad2(m) + '-' + pad2(dy);
  }

  function cssVar(name) {
    try {
      var v = getComputedStyle(document.documentElement).getPropertyValue(name);
      return (v || '').trim() || '#94A3B8';
    } catch (e) { return '#94A3B8'; }
  }

  function niceStep(span, want) {
    var raw = span / Math.max(1, want);
    if (!(raw > 0)) return 1;
    var mag = Math.pow(10, Math.floor(Math.log10(raw)));
    var norm = raw / mag;
    var mult = norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 5 ? 5 : 10;
    return mult * mag;
  }

  function yTicks(min, max, want) {
    var span = max - min;
    if (!(span > 0)) span = Math.abs(max) || 1;
    var step = niceStep(span, want);
    var start = Math.ceil(min / step - 1e-9) * step;
    var out = [];
    for (var i = 0; i < 40; i++) {
      var v = Math.round((start + step * i) / step) * step;
      if (v > max + step * 1e-6) break;
      if (v >= min - step * 1e-6) out.push(v);
    }
    if (!out.length) out = [min, max];
    return { values: out, step: step };
  }

  function decForStep(step) {
    if (step >= 1) return 0;
    if (step >= 0.1) return 1;
    if (step >= 0.01) return 2;
    return 3;
  }

  function group(v, dec) {
    var s = Number(v).toFixed(dec);
    var neg = s.charAt(0) === '-';
    if (neg) s = s.slice(1);
    var p = s.split('.');
    p[0] = p[0].replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    return (neg ? '-' : '') + p.join('.');
  }

  /* 数据缺口：按频率给出"正常间隔"与"异常阈值"（天；日内序列按分钟折算） */
  function gapThreshold(freq) {
    if (freq === 'intraday') return 5 / 1440;
    return freq === 'weekly' ? 10 : freq === 'monthly' ? 45 : 4;
  }
  function typicalGap(freq) {
    if (freq === 'intraday') return 1 / 1440;
    return freq === 'weekly' ? 7 : freq === 'monthly' ? 30 : 3;
  }

  function findGaps(points, freq) {
    var th = gapThreshold(freq);
    var typ = typicalGap(freq);
    var intraday = freq === 'intraday' ||
      (points.length > 1 && /[ T]\d{1,2}:\d{2}/.test(String(points[0][0])));
    var out = [];
    for (var i = 1; i < points.length; i++) {
      var a = toTime(points[i - 1][0]);
      var b = toTime(points[i][0]);
      if (intraday) {
        var mins = (b - a) / 60000;
        if (mins > 5) {
          out.push({
            from: points[i - 1][0],
            to: points[i][0],
            minutes: Math.round(mins),
            missing: Math.round(mins),
            index: i
          });
        }
        continue;
      }
      var d = Math.round((b - a) / DAY);
      if (d > th) {
        out.push({
          from: points[i - 1][0],
          to: points[i][0],
          days: d,
          missing: Math.max(1, d - typ),
          index: i
        });
      }
    }
    return out;
  }

  function nearest(pts, t) {
    var lo = 0, hi = pts.length - 1;
    if (!pts.length) return null;
    while (hi - lo > 1) {
      var mid = (lo + hi) >> 1;
      if (pts[mid].t < t) lo = mid; else hi = mid;
    }
    return Math.abs(pts[lo].t - t) <= Math.abs(pts[hi].t - t) ? pts[lo] : pts[hi];
  }

  /* ------------------------------------------------------------------ 折线 */

  function LineChart(host, cfg) {
    this.host = host;
    this.cfg = Object.assign({ height: 300, freq: 'daily', area: true, normalize: false }, cfg || {});
    this.tipEl = null;
    var self = this;
    this._onResize = function () { self.draw(); };
    window.addEventListener('resize', this._onResize);
    this.draw();
  }

  LineChart.prototype.destroy = function () {
    window.removeEventListener('resize', this._onResize);
    if (this.tipEl && this.tipEl.parentNode) this.tipEl.parentNode.removeChild(this.tipEl);
    this.tipEl = null;
    if (this.host) this.host.innerHTML = '';
  };

  LineChart.prototype._tip = function () {
    if (!this.tipEl) {
      var d = document.createElement('div');
      d.className = 'chart-tooltip';
      d.style.display = 'none';
      document.body.appendChild(d);
      this.tipEl = d;
    }
    return this.tipEl;
  };

  LineChart.prototype.draw = function () {
    var cfg = this.cfg;
    var host = this.host;
    if (!host) return;

    host.innerHTML = '';

    var raw = (cfg.series || []).filter(function (s) { return s && s.points && s.points.length; });
    if (!raw.length) {
      host.innerHTML = '<div class="empty" style="padding:60px 0"><div class="big">∅</div>暂无数据</div>';
      return;
    }

    var W = Math.round(host.clientWidth || host.getBoundingClientRect().width || 820);
    if (!(W > 120)) W = 820;
    var H = cfg.height || 300;
    var pad = { t: 16, r: 20, b: 30, l: W < 460 ? 50 : 64 };
    var plotW = Math.max(20, W - pad.l - pad.r);
    var plotH = Math.max(20, H - pad.t - pad.b);

    var colors = {
      grid: cssVar('--border'),
      text: cssVar('--text-2'),
      text3: cssVar('--text-3'),
      surface: cssVar('--surface')
    };

    /* --- 序列标准化 --- */
    var norm = !!cfg.normalize;
    var series = raw.map(function (s, i) {
      var pts = s.points.map(function (p) {
        return { t: toTime(p[0]), v: parseFloat(p[1]), d: p[0] };
      }).filter(function (p) { return isFinite(p.v); });
      var base = 0;
      if (norm) {
        base = pts.length ? pts[0].v : 0;
        pts = pts.map(function (p) {
          return { t: p.t, v: base ? (p.v / base) * 100 : 100, d: p.d, raw: p.v };
        });
      }
      return {
        pts: pts,
        color: s.color || PALETTE[i % PALETTE.length],
        label: s.label || '',
        freq: s.freq || cfg.freq,
        noGap: s.demo === false   // 交易所公开数据本身连续，不做缺口断线
      };
    }).filter(function (s) { return s.pts.length; });

    if (!series.length) {
      host.innerHTML = '<div class="empty" style="padding:60px 0">暂无有效数据</div>';
      return;
    }

    /* --- 值域 --- */
    var tMin = Infinity, tMax = -Infinity, vMin = Infinity, vMax = -Infinity;
    series.forEach(function (s) {
      s.pts.forEach(function (p) {
        if (p.t < tMin) tMin = p.t;
        if (p.t > tMax) tMax = p.t;
        if (p.v < vMin) vMin = p.v;
        if (p.v > vMax) vMax = p.v;
      });
    });
    if (tMax === tMin) tMax = tMin + DAY;
    var spanV = vMax - vMin;
    if (!(spanV > 0)) spanV = Math.abs(vMax) * 0.02 || 1;
    var yLo = vMin - spanV * 0.10;
    var yHi = vMax + spanV * 0.10;

    /* 先定 Y 轴刻度，再按刻度文字宽度反推左侧留白，避免与竖排单位挤在一起 */
    var yt0 = yTicks(yLo, yHi, 5);
    var yDec0 = Math.max(decForStep(yt0.step), cfg.minDecimals || 0);
    if (cfg.maxDecimals != null) yDec0 = Math.min(yDec0, cfg.maxDecimals);
    var maxChars = 0;
    yt0.values.forEach(function (v) {
      var len = group(v, yDec0).length;
      if (len > maxChars) maxChars = len;
    });
    var needL = Math.round(maxChars * 6.6) + (cfg.unit ? 30 : 18);
    if (W < 460) needL = Math.min(needL, 52);
    pad.l = Math.max(W < 460 ? 50 : 64, Math.min(needL, W < 460 ? 52 : 128));
    plotW = Math.max(20, W - pad.l - pad.r);

    var x = function (t) { return pad.l + ((t - tMin) / (tMax - tMin)) * plotW; };
    var y = function (v) { return pad.t + (1 - (v - yLo) / (yHi - yLo)) * plotH; };

    var svg = el('svg', {
      width: W, height: H, viewBox: '0 0 ' + W + ' ' + H,
      role: 'img', 'aria-label': cfg.ariaLabel || '价格走势图'
    });

    /* --- 网格与 Y 轴 --- */
    var yt = yt0;
    var yDec = yDec0;
    yt.values.forEach(function (v) {
      var yy = y(v);
      svg.appendChild(el('line', {
        x1: pad.l, x2: pad.l + plotW, y1: yy, y2: yy,
        stroke: colors.grid, 'stroke-width': 1, 'shape-rendering': 'crispEdges'
      }));
      var tx = el('text', {
        x: pad.l - 9, y: yy + 4, 'text-anchor': 'end',
        'font-size': 11, fill: colors.text, 'font-family': 'inherit'
      });
      tx.textContent = group(v, yDec);
      svg.appendChild(tx);
    });

    /* Y 轴单位（竖排，左侧留白内） */
    if (cfg.unit) {
      var cy = pad.t + plotH / 2;
      var ut = el('text', {
        x: 0, y: 0, 'text-anchor': 'middle', 'font-size': 10,
        fill: colors.text3, 'font-family': 'inherit',
        transform: 'translate(13,' + cy.toFixed(1) + ') rotate(-90)'
      });
      ut.textContent = cfg.unit;
      svg.appendChild(ut);
    }

    /* --- X 轴 --- */
    var spanDays = (tMax - tMin) / DAY;
    var intraday = spanDays < 2;
    var xCount = intraday ? (W < 460 ? 3 : 6) : (W < 460 ? 3 : (spanDays > 120 ? 6 : 4));
    var xMode = intraday ? 'hm' : (spanDays > 320 ? 'ym' : 'md');

    if (intraday) {
      /* 日内：按真实数据点取刻度，标签用 HH:MM，避免出现「21:37」这类非整点 */
      var basePts = series[0].pts;
      var nmax = basePts.length - 1;
      for (var k = 0; k <= xCount; k++) {
        var idx = Math.round((nmax * k) / xCount);
        var p = basePts[idx];
        var xx0 = x(p.t);
        var xt0 = el('text', {
          x: xx0, y: H - 10, 'text-anchor': k === 0 ? 'start' : (k === xCount ? 'end' : 'middle'),
          'font-size': 11, fill: colors.text3, 'font-family': 'inherit'
        });
        xt0.textContent = fmtDate(p.t, 'hm');
        svg.appendChild(xt0);
      }
    } else {
      for (var i = 0; i <= xCount; i++) {
        var tt = tMin + ((tMax - tMin) * i) / xCount;
        var xx = x(tt);
        var xt = el('text', {
          x: xx, y: H - 10, 'text-anchor': 'middle',
          'font-size': 11, fill: colors.text3, 'font-family': 'inherit'
        });
        xt.textContent = fmtDate(tt, xMode);
        svg.appendChild(xt);
      }
    }

    /* --- 昨结参考线（日内图用） --- */
    if (cfg.refLine && isFinite(cfg.refLine.value) && cfg.refLine.value >= yLo && cfg.refLine.value <= yHi) {
      var ry = y(cfg.refLine.value);
      svg.appendChild(el('line', {
        x1: pad.l, x2: pad.l + plotW, y1: ry, y2: ry,
        stroke: colors.text3, 'stroke-width': 1, 'stroke-dasharray': '5 4', opacity: 0.9
      }));
      var rl = el('text', {
        x: pad.l + plotW - 2, y: ry - 5, 'text-anchor': 'end',
        'font-size': 10, fill: colors.text3, 'font-family': 'inherit'
      });
      rl.textContent = (cfg.refLine.label || '昨结') + ' ' + group(cfg.refLine.value, cfg.refLine.decimals != null ? cfg.refLine.decimals : decForStep(yt.step));
      svg.appendChild(rl);
    }

    /* --- 绘图区边框（底边） --- */
    svg.appendChild(el('line', {
      x1: pad.l, x2: pad.l + plotW, y1: pad.t + plotH, y2: pad.t + plotH,
      stroke: colors.grid, 'stroke-width': 1, 'shape-rendering': 'crispEdges'
    }));

    /* --- 面积渐变（仅单序列） --- */
    if (cfg.area && series.length === 1) {
      var gid = 'mc-grad-' + (++uid);
      var defs = el('defs');
      var lg = el('linearGradient', { id: gid, x1: '0', y1: '0', x2: '0', y2: '1' });
      lg.appendChild(el('stop', { offset: '0%', 'stop-color': series[0].color, 'stop-opacity': '0.22' }));
      lg.appendChild(el('stop', { offset: '100%', 'stop-color': series[0].color, 'stop-opacity': '0' }));
      defs.appendChild(lg);
      svg.appendChild(defs);
      this._gradId = gid;
    } else {
      this._gradId = null;
    }

    /* --- 折线分段绘制 --- */
    var self = this;
    var gapCount = 0;

    series.forEach(function (s, si) {
      var intraday = /[ T]\d{1,2}:\d{2}/.test(String(s.pts[0].d || ''));
      var th = s.noGap && !intraday ? Infinity : gapThreshold(s.freq);
      var segs = [];
      var cur = [s.pts[0]];
      for (var k = 1; k < s.pts.length; k++) {
        var delta = (s.pts[k].t - s.pts[k - 1].t) / DAY;
        if (intraday) {
          /* 日内：超过 5 分钟即视为断点（隔夜/午休不画连续线） */
          if (delta * 1440 > 5) { segs.push(cur); cur = []; }
        } else if (Math.round(delta) > th) {
          segs.push(cur); cur = [];
        }
        cur.push(s.pts[k]);
      }
      segs.push(cur);
      if (segs.length > 1 && si === 0) gapCount = segs.length - 1;

      function pathOf(arr) {
        var d = '';
        for (var j = 0; j < arr.length; j++) {
          d += (j ? 'L' : 'M') + x(arr[j].t).toFixed(2) + ',' + y(arr[j].v).toFixed(2);
        }
        return d;
      }

      /* 面积（仅首条单序列） */
      if (cfg.area && series.length === 1 && self._gradId) {
        segs.forEach(function (seg) {
          if (seg.length < 2) return;
          var base = pad.t + plotH;
          var d = pathOf(seg);
          d += 'L' + x(seg[seg.length - 1].t).toFixed(2) + ',' + base.toFixed(2);
          d += 'L' + x(seg[0].t).toFixed(2) + ',' + base.toFixed(2) + 'Z';
          svg.appendChild(el('path', { d: d, fill: 'url(#' + self._gradId + ')', stroke: 'none' }));
        });
      }

      /* 缺口处虚线连接，不直连 */
      for (var g = 1; g < segs.length; g++) {
        var a = segs[g - 1][segs[g - 1].length - 1];
        var b = segs[g][0];
        svg.appendChild(el('path', {
          d: 'M' + x(a.t).toFixed(2) + ',' + y(a.v).toFixed(2) +
             'L' + x(b.t).toFixed(2) + ',' + y(b.v).toFixed(2),
          fill: 'none', stroke: s.color, 'stroke-width': 1.4,
          'stroke-dasharray': '4 4', opacity: 0.55, 'stroke-linecap': 'round'
        }));
        /* 缺口标记：两端小空心点 */
        [a, b].forEach(function (p) {
          svg.appendChild(el('circle', {
            cx: x(p.t).toFixed(2), cy: y(p.v).toFixed(2), r: 2.4,
            fill: colors.surface, stroke: s.color, 'stroke-width': 1.3, opacity: 0.8
          }));
        });
      }

      /* 实线 */
      segs.forEach(function (seg) {
        if (seg.length === 1) {
          svg.appendChild(el('circle', {
            cx: x(seg[0].t).toFixed(2), cy: y(seg[0].v).toFixed(2), r: 2.2, fill: s.color
          }));
          return;
        }
        svg.appendChild(el('path', {
          d: pathOf(seg), fill: 'none', stroke: s.color,
          'stroke-width': si === 0 ? 2 : 1.8,
          'stroke-linejoin': 'round', 'stroke-linecap': 'round'
        }));
      });

      /* 末点强调 */
      var last = s.pts[s.pts.length - 1];
      svg.appendChild(el('circle', {
        cx: x(last.t).toFixed(2), cy: y(last.v).toFixed(2), r: 5.5,
        fill: s.color, opacity: 0.18
      }));
      svg.appendChild(el('circle', {
        cx: x(last.t).toFixed(2), cy: y(last.v).toFixed(2), r: 3,
        fill: s.color, stroke: colors.surface, 'stroke-width': 1.5
      }));
    });

    this.gapCount = gapCount;

    /* --- 悬停层 --- */
    var guide = el('line', {
      x1: 0, x2: 0, y1: pad.t, y2: pad.t + plotH,
      stroke: colors.text3, 'stroke-width': 1, 'stroke-dasharray': '3 3', opacity: 0
    });
    svg.appendChild(guide);

    var dots = series.map(function (s) {
      var c = el('circle', { r: 4, fill: s.color, stroke: colors.surface, 'stroke-width': 2, opacity: 0 });
      svg.appendChild(c);
      return c;
    });

    var overlay = el('rect', {
      x: pad.l, y: pad.t, width: plotW, height: plotH, fill: 'transparent',
      style: 'cursor:crosshair'
    });
    svg.appendChild(overlay);

    host.appendChild(svg);

    var hide = function () {
      guide.setAttribute('opacity', '0');
      dots.forEach(function (d) { d.setAttribute('opacity', '0'); });
      var tip = self._tip();
      tip.style.display = 'none';
    };

    overlay.addEventListener('mousemove', function (ev) {
      var r = svg.getBoundingClientRect();
      if (!r.width) return;
      var px = (ev.clientX - r.left) * (W / r.width);
      if (px < pad.l - 8 || px > pad.l + plotW + 8) { hide(); return; }
      var t = tMin + ((px - pad.l) / plotW) * (tMax - tMin);

      var primary = series[0].pts;
      var np = nearest(primary, t);
      if (!np) return;
      var t0 = np.t;

      guide.setAttribute('x1', x(t0));
      guide.setAttribute('x2', x(t0));
      guide.setAttribute('opacity', '1');

      var rows = [];
      series.forEach(function (s, si) {
        var p = nearest(s.pts, t0);
        if (!p) { dots[si].setAttribute('opacity', '0'); return; }
        dots[si].setAttribute('cx', x(p.t));
        dots[si].setAttribute('cy', y(p.v));
        dots[si].setAttribute('opacity', '1');
        rows.push({ color: s.color, label: s.label, point: p, series: s });
      });
      if (!rows.length) { hide(); return; }

      var html;
      if (typeof cfg.tipRender === 'function') {
        html = cfg.tipRender(t0, rows);
      } else {
        var dec = yDec;
        html = '<div class="tt-date">' + fmtDate(t0, 'full') +
          (intraday ? ' ' + fmtDate(t0, 'hm') : '') + '</div>';
        rows.forEach(function (row) {
          html += '<div class="tt-row">' +
            '<span class="tt-dot" style="background:' + row.color + '"></span>' +
            '<span class="tt-k">' + (row.label || '价格') + '</span>' +
            '<span class="tt-v">' + group(row.point.v, dec) +
            (cfg.unit ? ' ' + cfg.unit : '') + '</span></div>';
        });
      }

      var tip = self._tip();
      tip.innerHTML = html;
      tip.style.display = 'block';

      var tw = tip.offsetWidth, th = tip.offsetHeight;
      var left = ev.clientX + 14;
      var top = ev.clientY - th - 12;
      if (left + tw > window.innerWidth - 10) left = ev.clientX - tw - 14;
      if (left < 8) left = 8;
      if (top < 8) top = ev.clientY + 18;
      tip.style.left = left + 'px';
      tip.style.top = top + 'px';
    });

    overlay.addEventListener('mouseleave', hide);
  };

  /* ---------------------------------------------------------------- 迷你图 */

  function spark(host, values, color) {
    if (!host) return;
    host.innerHTML = '';
    if (!values || values.length < 2) return;
    var min = Infinity, max = -Infinity;
    values.forEach(function (v) { if (v < min) min = v; if (v > max) max = v; });
    var span = max - min || 1;
    var W = 100, H = 30, p = 4;
    var pts = values.map(function (v, i) {
      var xx = (i / (values.length - 1)) * W;
      var yy = p + (1 - (v - min) / span) * (H - p * 2);
      return xx.toFixed(2) + ',' + yy.toFixed(2);
    });
    var svg = el('svg', {
      viewBox: '0 0 ' + W + ' ' + H, preserveAspectRatio: 'none',
      width: '100%', height: '100%', 'aria-hidden': 'true'
    });
    svg.appendChild(el('polygon', {
      points: '0,' + H + ' ' + pts.join(' ') + ' ' + W + ',' + H,
      fill: color, opacity: 0.10
    }));
    svg.appendChild(el('polyline', {
      points: pts.join(' '), fill: 'none', stroke: color, 'stroke-width': 1.6,
      'stroke-linejoin': 'round', 'stroke-linecap': 'round',
      'vector-effect': 'non-scaling-stroke'
    }));
    host.appendChild(svg);
  }

  global.MineChart = {
    line: function (host, cfg) { return new LineChart(host, cfg); },
    spark: spark,
    findGaps: findGaps,
    css: cssVar,
    palette: PALETTE,
    toTime: toTime
  };
}(window));
