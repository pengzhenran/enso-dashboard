// 小程序工程自检
//
// 微信开发者工具无法在命令行里跑，所以这里做两件事：
//   A. 静态检查：JSON 可解析、页面文件齐全、WXML 绑定的方法在 JS 里存在、
//      canvas id 对得上、引用的图片存在
//   B. 行为检查：用一个 canvas 桩真实执行 utils/chart.js、utils/map.js、
//      utils/readout.js，验证窗口钳制、年数切换、抽稀、路径解析、节流等逻辑
//
// 用法：node scripts/verify-miniprogram.mjs

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const mp = join(root, 'miniprogram');

let pass = 0, fail = 0;
const failures = [];

function ok(name, cond, detail) {
  if (cond) { pass++; }
  else { fail++; failures.push(name + (detail ? ' — ' + detail : '')); }
}
function section(t) { console.log('\n' + t); }

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const f = join(dir, name);
    if (statSync(f).isDirectory()) walk(f, out);
    else out.push(f);
  }
  return out;
}

// ═══════════════════════════════════════════ A. 结构与语法

section('A. 结构与语法');

const appJson = JSON.parse(readFileSync(join(mp, 'app.json'), 'utf8'));
ok('app.json 可解析', !!appJson.pages);
ok('app.json 声明了页面', appJson.pages.length > 0, appJson.pages.length + ' 个');

// 每个页面必须有 4 个文件
for (const p of appJson.pages) {
  for (const ext of ['js', 'json', 'wxml', 'wxss']) {
    ok(`${p}.${ext} 存在`, existsSync(join(mp, p + '.' + ext)));
  }
}

// tabBar 里的路径必须在 pages 里
for (const it of ((appJson.tabBar && appJson.tabBar.list) || [])) {
  ok(`tabBar「${it.text}」指向已声明页面`, appJson.pages.includes(it.pagePath), it.pagePath);
}

// 所有 .js 语法可解析
const jsFiles = walk(mp).filter((f) => f.endsWith('.js'));
for (const f of jsFiles) {
  try {
    execFileSync(process.execPath, ['--check', f], { stdio: 'pipe' });
    pass++;
  } catch (e) {
    fail++;
    failures.push('语法错误：' + f.replace(root + '\\', '') + '\n' +
      String(e.stderr || e.message).split('\n').slice(0, 4).join('\n'));
  }
}
console.log(`  ${jsFiles.length} 个 JS 文件语法检查完成`);

// 所有 .json 可解析
for (const f of walk(mp).filter((x) => x.endsWith('.json'))) {
  try { JSON.parse(readFileSync(f, 'utf8')); pass++; }
  catch (e) { fail++; failures.push('JSON 解析失败：' + f + ' — ' + e.message); }
}

// WXSS 大括号配对
for (const f of walk(mp).filter((x) => x.endsWith('.wxss'))) {
  const s = readFileSync(f, 'utf8');
  const open = (s.match(/{/g) || []).length;
  const close = (s.match(/}/g) || []).length;
  ok('WXSS 大括号配对：' + f.replace(mp + '\\', ''), open === close, `${open} vs ${close}`);
}

// ═══════════════════════════════════════════ B. 绑定一致性

section('B. WXML ↔ JS 绑定一致性');

for (const p of appJson.pages) {
  const wxml = readFileSync(join(mp, p + '.wxml'), 'utf8');
  const js = readFileSync(join(mp, p + '.js'), 'utf8');
  const json = JSON.parse(readFileSync(join(mp, p + '.json'), 'utf8'));
  const short = p.split('/').pop();

  // 事件绑定的方法名必须在 JS 里定义
  const handlers = new Set();
  const re = /\b(?:bind|catch)(?::)?([a-z]+)\s*=\s*"([^"{}]+)"/g;
  let m;
  while ((m = re.exec(wxml)) !== null) handlers.add(m[2]);
  for (const h of handlers) {
    const defined = new RegExp('(^|[\\s,{])' + h + '\\s*:\\s*function').test(js) ||
                    new RegExp('(^|[\\s,{])' + h + '\\s*\\([^)]*\\)\\s*{').test(js);
    ok(`${short}: 事件方法 ${h}() 已定义`, defined);
  }

  // canvas id 必须两边都有，且带 type="2d"
  const ids = [...wxml.matchAll(/<canvas[^>]*id="([^"]+)"/g)].map((x) => x[1]);
  for (const id of ids) {
    ok(`${short}: JS 里引用了画布 ${id}`, js.includes("'#" + id + "'") || js.includes('"#' + id + '"'));
    const tag = wxml.match(new RegExp('<canvas[^>]*id="' + id + '"[^>]*>'))[0];
    ok(`${short}: 画布 ${id} 带 type="2d"`, /type\s*=\s*"2d"/.test(tag));
  }

  ok(`${short}.json 有 usingComponents`, 'usingComponents' in json);
}

// ═══════════════════════════════════════════ canvas 桩

function makeCtxStub() {
  const calls = { moveTo: 0, lineTo: 0, arc: 0, fillText: 0, fillRect: 0, stroke: 0, fill: 0, clearRect: 0 };
  const pts = [];
  const texts = [];
  const transform = { a: 1, d: 1 };
  return {
    calls, pts, texts, transform,
    setTransform(a, b, c, d) { transform.a = a; transform.d = d; },
    clearRect() { calls.clearRect++; },
    beginPath() {}, closePath() {},
    moveTo(x, y) { calls.moveTo++; pts.push([x, y]); },
    lineTo(x, y) { calls.lineTo++; pts.push([x, y]); },
    arc(x, y, r) { calls.arc++; pts.push([x, y, r]); },
    arcTo() {}, rect() {},
    fillRect() { calls.fillRect++; },
    stroke() { calls.stroke++; }, fill() { calls.fill++; },
    fillText(t, x, y) { calls.fillText++; texts.push([String(t), x, y]); },
    measureText(t) { return { width: String(t).length * 6 }; },
    setLineDash() {}, save() {}, restore() {},
    set font(v) { this._font = v; }, get font() { return this._font || '10px sans-serif'; },
    set fillStyle(v) { this._fill = v; }, get fillStyle() { return this._fill; },
    set strokeStyle(v) { this._stroke = v; }, get strokeStyle() { return this._stroke; },
    set lineWidth(v) {}, set textAlign(v) {}, set textBaseline(v) {},
    set lineJoin(v) {},
    set globalAlpha(v) { this._alpha = v; }, get globalAlpha() { return this._alpha; }
  };
}

// ═══════════════════════════════════════════ C. 图表引擎

section('C. 图表引擎行为（真实执行）');

const mpUrl = pathToFileURL(mp + '\\').href;
const { createChart } = await import(mpUrl + 'utils/chart.js');
const weekly = (await import(mpUrl + 'data/weekly.js')).default;
const theme = (await import(mpUrl + 'utils/theme.js')).default;

function buildChart(cfg, w = 340, h = 260) {
  const ctx = makeCtxStub();
  const readouts = [];
  const chart = createChart({
    canvas: undefined,          // 无 rAF，schedule() 退化为同步 render
    ctx, width: w, height: h, dpr: 3,
    cfg,
    onReadout: (t) => readouts.push(t)
  });
  return { chart, ctx, readouts };
}

const weeklyCfg = {
  labels: weekly.labels.map((s) => s.slice(2, 7).replace('-', '/')),
  tips: weekly.labels,
  type: 'line', zoom: true, minSpan: 8, defaultYears: 3,
  series: [
    { name: 'Niño1+2', color: theme.n12, data: weekly.n12, unit: '°C' },
    { name: 'Niño3', color: theme.n3, data: weekly.n3, unit: '°C' },
    { name: 'Niño3.4', color: theme.n34, data: weekly.n34, width: 2.4, unit: '°C' },
    { name: 'Niño4', color: theme.n4, data: weekly.n4, unit: '°C' },
    { name: 'Niño3.4 相对', color: theme.rel, data: weekly.r34, dash: [5, 4], unit: '°C' }
  ]
};

// 默认 3 年窗口
{
  const { chart, ctx, readouts } = buildChart(weeklyCfg);
  chart.render();
  const st = chart.state;
  ok('默认窗口右端对齐最新数据', st.hi === weekly.labels.length - 1, `hi=${st.hi}`);
  const span = st.hi - st.lo + 1;
  ok('默认窗口约 156 周（3 年）', span >= 150 && span <= 165, 'span=' + span);
  ok('窗口索引为整数（否则取值会 undefined）', Number.isInteger(st.lo) && Number.isInteger(st.hi));
  ok('实际绘制了折线', ctx.calls.lineTo > 100, 'lineTo=' + ctx.calls.lineTo);
  ok('五条序列都画了', ctx.calls.stroke >= 5, 'stroke=' + ctx.calls.stroke);
  // 断言「总点数 == 实际数据长度」，而不是写死某个数字。
  // 数据每周都会增长，写死 2353 会让这个检查每周假失败一次。
  {
    const readout = readouts[readouts.length - 1] || '';
    ok('读数条含「/ 总点数 点」格式', /\/ \d+ 点/.test(readout), readout);
    ok('读数条的总点数等于实际数据长度',
      new RegExp('/ ' + weekly.labels.length + ' 点').test(readout),
      `期望 / ${weekly.labels.length} 点，实际「${readout}」`);
  }
  ok('dpr 变换已应用', ctx.transform.a === 3, 'a=' + ctx.transform.a);
}

// 年数切换
for (const [years, lo, hi] of [[1, 40, 60], [5, 240, 280], [10, 490, 540], [20, 990, 1060]]) {
  const { chart } = buildChart(weeklyCfg);
  chart.setSpan(years);
  const span = chart.state.hi - chart.state.lo + 1;
  ok(`${years} 年窗口周数合理`, span >= lo && span <= hi, 'span=' + span);
}
{
  const { chart } = buildChart(weeklyCfg);
  chart.setSpan(0);
  ok('「全部」窗口覆盖整段序列', chart.state.lo === 0 && chart.state.hi === weekly.labels.length - 1);
}

// 抽稀不能丢掉右端点
{
  const { chart, ctx } = buildChart(weeklyCfg, 340, 260);
  chart.setSpan(0);                    // 全部历史，触发抽稀
  const maxX = Math.max(...ctx.pts.filter((p) => p.length === 2).map((p) => p[0]));
  const expected = 48 + (340 - 48 - 14);   // PAD.l + f.W
  ok('抽稀后曲线右端点未被截短', Math.abs(maxX - expected) < 12, `maxX=${maxX.toFixed(1)} expected≈${expected}`);
  // 阈值用实际数据长度算，不写死数字——数据每周增长，写死会越来越松，失去意义
  ok('抽稀确实减少了绘制量',
    ctx.calls.lineTo < weekly.labels.length * 5,
    `lineTo=${ctx.calls.lineTo}, 上限=${weekly.labels.length * 5}`);
}

// 缩放与平移
{
  const { chart } = buildChart(weeklyCfg);
  const before = chart.state.hi - chart.state.lo;
  chart.zoom(0.5);
  const after = chart.state.hi - chart.state.lo;
  ok('放大后窗口变窄', after < before, `${before} → ${after}`);
  ok('放大不会越过最小窗口', after >= 7, 'span=' + after);
  chart.zoom(100);
  ok('缩放到上限时覆盖全部', chart.state.lo === 0 && chart.state.hi === weekly.labels.length - 1);

  chart.setSpan(3);
  const lo0 = chart.state.lo;
  // 默认窗口贴在最右端（最新数据），往前平移才应该生效
  chart.pan(-0.35);
  ok('平移（回溯）改变了窗口起点', chart.state.lo < lo0, `${lo0} → ${chart.state.lo}`);
  ok('平移不越界', chart.state.lo >= 0 && chart.state.hi <= weekly.labels.length - 1);

  // 反方向平移应被钳制在最新数据一端，而不是越界
  const span1 = chart.state.hi - chart.state.lo;
  chart.pan(0.35);
  chart.pan(0.35);                     // 多推一次，确保是钳制而不是刚好回到原位
  const last = weekly.labels.length - 1;
  ok('贴边后继续往后平移被钳制在最新数据端',
    chart.state.hi === last && chart.state.lo === last - span1,
    `lo=${chart.state.lo} hi=${chart.state.hi} 期望 lo=${last - span1} hi=${last}`);
  ok('钳制过程没有改变窗口长度', chart.state.hi - chart.state.lo === span1);
}

// 触摸交互：单击定位 → 再点取消
{
  const { chart } = buildChart(weeklyCfg);
  const mid = 20 + (340 - 20 - 14) / 2;
  chart.touchStart({ touches: [{ x: mid, y: 100 }] });
  chart.touchEnd({ touches: [] });
  ok('轻点图表后定位到某个点', chart.state.mark !== null && chart.state.mark !== undefined,
    'mark=' + chart.state.mark);
  chart.touchStart({ touches: [{ x: mid, y: 100 }] });
  chart.touchEnd({ touches: [] });
  ok('再点同一点取消定位', chart.state.mark === null);
}

// 触摸交互：拖动平移不被当成点击（不能被误标）
{
  const { chart } = buildChart(weeklyCfg);
  const lo0 = chart.state.lo;
  // 向右拖动 = 回到更早的时间（与网页版「抓住内容往右拉」一致）
  chart.touchStart({ touches: [{ x: 60, y: 100 }] });
  chart.touchMove({ touches: [{ x: 140, y: 100 }] });
  chart.touchMove({ touches: [{ x: 200, y: 100 }] });
  chart.touchEnd({ touches: [] });
  ok('拖动改变了窗口起点', chart.state.lo < lo0, `${lo0} → ${chart.state.lo}`);
  ok('拖动不会被误判成点击定位', chart.state.mark === null, 'mark=' + chart.state.mark);
}

// 双指捏合
{
  const { chart } = buildChart(weeklyCfg);
  const before = chart.state.hi - chart.state.lo;
  chart.touchStart({ touches: [{ x: 150, y: 100 }, { x: 190, y: 100 }] });   // 间距 40
  chart.touchMove({ touches: [{ x: 120, y: 100 }, { x: 220, y: 100 }] });    // 间距 100 → 放大
  const after = chart.state.hi - chart.state.lo;
  ok('双指分开 → 窗口变窄（放大）', after < before, `${before} → ${after}`);
}

// 边界：整窗缺测不应崩
{
  const cfg = {
    labels: ['A', 'B', 'C'], tips: ['A', 'B', 'C'], type: 'line', zoom: false,
    series: [{ name: 'x', color: '#fff', data: [null, null, null] }]
  };
  const { chart } = buildChart(cfg, 200, 150);
  let threw = false;
  try { chart.render(); } catch (e) { threw = true; }
  ok('整窗无数据时 render() 不抛异常', !threw);
}

// 非法窗口不会被写进状态
{
  const { chart } = buildChart(weeklyCfg);
  chart.setSpan(0);
  chart.touchStart({ touches: [{ x: -500, y: 100 }] });
  chart.touchEnd({ touches: [] });
  ok('窗口索引始终落在合法区间',
    chart.state.lo >= 0 && chart.state.hi <= weekly.labels.length - 1 && chart.state.lo <= chart.state.hi);
}

// 降级：基础库若缺少 setLineDash / arcTo / measureText，render() 不能崩
// （一旦抛异常，画布会整块白屏，所以这些 API 都必须有兜底）
{
  function makeMinimalCtx() {
    const c = { strokes: 0 };
    return {
      _c: c,
      setTransform() {}, clearRect() {}, beginPath() {}, closePath() {},
      moveTo() {}, lineTo() {}, arc() {}, fill() {}, stroke() { c.strokes++; },
      fillRect() {}, fillText() {}, rect() {},
      set font(v) {}, get font() { return ''; },
      set fillStyle(v) {}, set strokeStyle(v) {},
      set lineWidth(v) {}, set textAlign(v) {}, set textBaseline(v) {},
      set lineJoin(v) {}, set globalAlpha(v) {}
      // 刻意不提供 setLineDash / arcTo / measureText
    };
  }

  const cfgWithDash = {
    labels: ['a', 'b', 'c', 'd'], tips: ['a', 'b', 'c', 'd'],
    type: 'line', zoom: true, minSpan: 2, defaultYears: 1,
    series: [{ name: 'dashed', color: '#fff', data: [1, 2, 3, 4], dash: [5, 4] }]
  };
  const ctx = makeMinimalCtx();
  const chart = createChart({ canvas: undefined, ctx, width: 300, height: 200, dpr: 2, cfg: cfgWithDash });

  let threw = null;
  try {
    chart.render();                                    // 触发 setLineDash 兜底
    chart.touchStart({ touches: [{ x: 150, y: 100 }] });
    chart.touchEnd({ touches: [] });                   // 触发 tooltip（measureText + arcTo）兜底
  } catch (e) { threw = e; }
  ok('缺少 setLineDash / arcTo / measureText 时仍能绘制', !threw, threw && threw.message);
  ok('降级后确实画出了内容', ctx._c.strokes > 0, 'stroke=' + ctx._c.strokes);
}

// resize：横竖屏切换 / 进出全屏后必须重设画布位图尺寸。
// 只改 CSS 高度是不够的 —— canvas 的位图尺寸独立于 CSS 尺寸，
// 不同步就会把内容拉伸变糊，而且不会报任何错。
{
  const ctx = makeCtxStub();
  const fakeCanvas = { width: 0, height: 0 };
  const chart = createChart({
    canvas: fakeCanvas, ctx, width: 340, height: 260, dpr: 2, cfg: weeklyCfg,
    onReadout: function () {}
  });
  chart.render();
  const before = ctx.calls.lineTo;

  chart.resize(600, 300);
  ok('resize 按 dpr 重设画布位图宽度', fakeCanvas.width === 1200, 'width=' + fakeCanvas.width);
  ok('resize 按 dpr 重设画布位图高度', fakeCanvas.height === 600, 'height=' + fakeCanvas.height);
  ok('resize 后自动重绘', ctx.calls.lineTo > before, `${before} → ${ctx.calls.lineTo}`);

  // 非法的 0 尺寸必须被忽略，而不是把画布改成 0 导致空白
  chart.resize(0, 100);
  ok('resize 忽略 0 尺寸', fakeCanvas.width === 1200 && fakeCanvas.height === 600,
    `${fakeCanvas.width}x${fakeCanvas.height}`);

  // 没有 canvas 节点时（本测试环境、或降级）不能抛异常
  const chart2 = createChart({
    canvas: undefined, ctx: makeCtxStub(), width: 300, height: 200, dpr: 2, cfg: weeklyCfg
  });
  let threw = false;
  try { chart2.resize(400, 250); } catch (e) { threw = true; }
  ok('无 canvas 节点时 resize 不抛异常', !threw);
}

// ═══════════════════════════════════════════ D. 读数条节流器

section('D. 读数条节流器（真实执行）');

const { createReadout } = await import(mpUrl + 'utils/readout.js');
{
  const applied = [];
  const fakePage = { setData: (d) => applied.push(d.readout) };
  const r = createReadout(fakePage, 'readout', 120);

  r.set('A');
  ok('首个读数立即生效（保证响应感）', applied.length === 1 && applied[0] === 'A', JSON.stringify(applied));

  r.set('B'); r.set('C'); r.set('D');
  ok('节流窗口内不重复触发 setData', applied.length === 1, 'applied=' + applied.length);

  await new Promise((res) => setTimeout(res, 200));
  ok('窗口结束后合并成一次更新', applied.length === 2, 'applied=' + JSON.stringify(applied));
  ok('合并后落定的是最后一次的值', applied[1] === 'D', JSON.stringify(applied));

  r.set('E'); r.set('F');
  r.end();
  ok('end() 立刻落定最终值（不停在中途状态）', applied[applied.length - 1] === 'F', JSON.stringify(applied));

  const n = applied.length;
  r.set('F');
  r.end();
  ok('值没变化时不触发 setData（省桥接流量）', applied.length === n, JSON.stringify(applied));
}

// ═══════════════════════════════════════════ E. 地图

section('E. 地图路径解析（真实执行）');

const mapLib = await import(mpUrl + 'utils/map.js');
const basemapPath = (await import(mpUrl + 'data/basemap.js')).default;
const cmds = mapLib.parsePath(basemapPath);

ok('底图是路径字符串', typeof basemapPath === 'string' && basemapPath.startsWith('M'));
ok('底图命令已解析', cmds.length > 100, cmds.length + ' 条');

const bag = new Set(cmds.map((c) => c.t));
ok('只出现已知的路径命令', [...bag].every((t) => 'MLZmlzHhVv'.includes(t)), [...bag].join(''));

// 坐标范围检查：全部应在 viewBox 内
let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
for (const c of cmds) {
  const up = c.t.toUpperCase();
  if (up !== 'M' && up !== 'L') continue;
  for (let i = 0; i + 1 < c.n.length; i += 2) {
    minX = Math.min(minX, c.n[i]); maxX = Math.max(maxX, c.n[i]);
    minY = Math.min(minY, c.n[i + 1]); maxY = Math.max(maxY, c.n[i + 1]);
  }
}
ok('底图 x 落在 0..360', minX >= -1 && maxX <= 361, `[${minX}, ${maxX}]`);
ok('底图 y 落在 0..180', minY >= -1 && maxY <= 181, `[${minY}, ${maxY}]`);

const impactsSrc = readFileSync(join(mp, 'data', 'impacts.js'), 'utf8');
ok('影响区数据含 DJF 与 JJA', /DJF:/.test(impactsSrc) && /JJA:/.test(impactsSrc));

// 用桩画一遍地图，确认不抛异常且画了圆点
{
  const ctx = makeCtxStub();
  const imp = (await import(mpUrl + 'data/impacts.js')).default;
  let threw = null;
  try {
    mapLib.drawImpactMap(ctx, { width: 340, height: 170, dpr: 3, season: 'DJF' });
  } catch (e) { threw = e; }
  ok('drawImpactMap 不抛异常', !threw, threw && threw.message);
  ok('底图陆地被描边', ctx.calls.stroke > 0);
  ok('区域编号圆点数量与数据一致',
    ctx.calls.arc === imp.IMPACTS.DJF.length, 'arc=' + ctx.calls.arc + ' 期望=' + imp.IMPACTS.DJF.length);
  ok('画出了 Niño3.4 标注', ctx.texts.some((t) => t[0] === 'Niño3.4'));

  // 换季也要能画
  let threw2 = null;
  try {
    mapLib.drawImpactMap(ctx, { width: 340, height: 170, dpr: 3, season: 'JJA' });
  } catch (e) { threw2 = e; }
  ok('切换到 JJA 也能绘制', !threw2, threw2 && threw2.message);

  // 降级：缺少 setLineDash / arcTo 时地图也不能崩
  const bare = {
    setTransform() {}, clearRect() {}, beginPath() {}, closePath() {},
    moveTo() {}, lineTo() {}, arc() {}, fill() {}, stroke() {}, fillRect() {},
    fillText() {}, rect() {},
    set fillStyle(v) {}, set strokeStyle(v) {}, set lineWidth(v) {},
    set textAlign(v) {}, set textBaseline(v) {}, set lineJoin(v) {},
    set globalAlpha(v) {}, set font(v) {}
  };
  let threw3 = null;
  try { mapLib.drawImpactMap(bare, { width: 340, height: 170, dpr: 3, season: 'DJF' }); }
  catch (e) { threw3 = e; }
  ok('缺少 setLineDash / arcTo 时地图仍能绘制', !threw3, threw3 && threw3.message);
}

// ═══════════════════════════════════════════ F. 图片资源

section('F. 图片资源');

const imgRefs = [
  ...readFileSync(join(mp, 'data', 'maps.js'), 'utf8').matchAll(/"([\w.\-]+\.(?:png|jpg|jpeg))"/g),
  ...readFileSync(join(mp, 'data', 'qrcode.js'), 'utf8').matchAll(/"([\w.\-]+\.(?:png|jpg|jpeg))"/g)
].map((m) => m[1]);

ok('至少释放了二维码图片', imgRefs.length >= 1, imgRefs.join(', '));
for (const f of new Set(imgRefs)) {
  const p = join(mp, 'images', f);
  ok('图片存在：' + f, existsSync(p));
  // 只查存在不够：CPC 回归图曾经是 GIF87a 却叫 .png（`.png` 后缀骗过所有人）。
  // 这里按文件头核对真实格式，别再让「后缀对、内容错」的东西进包。
  if (existsSync(p)) {
    const head = readFileSync(p).subarray(0, 8);
    const magicOk = (f.endsWith('.png') && head[0] === 0x89 && head.toString('latin1', 1, 4) === 'PNG')
      || ((f.endsWith('.jpg') || f.endsWith('.jpeg')) && head[0] === 0xff && head[1] === 0xd8);
    ok('图片格式与后缀一致：' + f, magicOk, head.toString('hex'));
  }
}

// ═══════════════════════════════════════════ G. 代码包体积

section('G. 代码包体积');

// 尊重 project.config.json 的 packOptions.ignore：这些文件在仓库里但不会被打包上传
const projCfg = JSON.parse(readFileSync(join(mp, 'project.config.json'), 'utf8'));
const ignored = ((projCfg.packOptions && projCfg.packOptions.ignore) || [])
  .map((x) => String(x.value).toLowerCase());
const isIgnored = (rel) => {
  const p = rel.replace(/\\/g, '/').toLowerCase();
  const base = p.split('/').pop();
  return ignored.some((v) => p === v || base === v || p.startsWith(v));
};

let total = 0, excluded = 0;
const byDir = {};
for (const f of walk(mp)) {
  const rel = f.replace(mp + '\\', '');
  const size = statSync(f).size;
  if (isIgnored(rel)) { excluded += size; continue; }
  total += size;
  const dir = rel.includes('\\') ? rel.split('\\')[0] : '(根目录)';
  byDir[dir] = (byDir[dir] || 0) + size;
}
for (const [d, s] of Object.entries(byDir).sort((a, b) => b[1] - a[1])) {
  console.log(`  ${d.padEnd(12)} ${(s / 1024).toFixed(1).padStart(8)} KB`);
}
console.log(`  ${'合计'.padEnd(12)} ${(total / 1024).toFixed(1).padStart(8)} KB`);
if (excluded) {
  console.log(`  （另有 ${(excluded / 1024).toFixed(1)} KB 被 packOptions.ignore 排除，不参与上传）`);
}
ok('packOptions 排除了 README.md 等非代码文件', excluded > 0, '排除 ' + (excluded / 1024).toFixed(1) + ' KB');
ok('主包体积 < 2 MB 上限', total < 2 * 1024 * 1024, (total / 1024).toFixed(1) + ' KB');
ok('主包体积留有一半余量', total < 1 * 1024 * 1024, (total / 1024).toFixed(1) + ' KB');

// ═══════════════════════════════════════════ H. 宽屏布局

section('H. 宽屏两栏与画布尺寸');

const idxWxml = readFileSync(join(mp, 'pages/index/index.wxml'), 'utf8');
const idxWxss = readFileSync(join(mp, 'pages/index/index.wxss'), 'utf8');
const appWxss = readFileSync(join(mp, 'app.wxss'), 'utf8');

// 两栏只靠 CSS 断点切换，wxml 结构必须一直在（手机端是一栏，结构相同）
ok('概览页有两栏壳 .cols / .col.ca / .col.cb',
  /class="cols"/.test(idxWxml) && /class="col ca"/.test(idxWxml) && /class="col cb"/.test(idxWxml));
ok('概览页页头分成数字区与图表区',
  /class="hgrid"/.test(idxWxml) && /class="hnum"/.test(idxWxml) && /class="hchart"/.test(idxWxml));
ok('两栏只在 >=820px 生效（手机不受影响）',
  /@media\s*\(min-width:\s*820px\)[\s\S]*?\.cols\s*\{\s*display:\s*flex/.test(idxWxss));
ok('宽屏容器放宽到 1040px',
  /@media\s*\(min-width:\s*820px\)[\s\S]*?1040px/.test(appWxss));

// canvas 的位图尺寸独立于 CSS：窗口尺寸一变（折叠屏展开/旋转/分屏）就必须重测重画，
// 否则内容被拉伸变糊且不报错。所以有 canvas 的页面都要有 onResize。
// 只匹配「有 onResize」太松：函数体被清空也照样通过。要求它真的调了重测。
// 另外折叠屏「展开」不一定派发 onResize，还要挂 wx.onWindowResize 兜一层。
for (const p of ['index', 'weekly', 'monthly', 'fan', 'impact']) {
  const js = readFileSync(join(mp, 'pages', p, p + '.js'), 'utf8');
  const m = js.match(/onResize:\s*function[\s\S]*?\n  \}/);
  const body = m ? m[0] : '';
  ok('有画布的页面实现 onResize（' + p + '）', !!m);
  ok('onResize 真的重测重画（' + p + '）', /remeasure\(\)|drawSpark\(\)/.test(body));
  ok('挂了 wx.onWindowResize 兜底（' + p + '）', /watchWindowResize\(this,\s*this\.\w+\)/.test(js));
}

// wx.onWindowResize 兜底：真实执行 canvas-init 的 watchWindowResize，
// 验证挂上、触发、不重复挂、卸载时摘掉（不摘会越积越多，每进一次页面多画一次）
const ciMod = await import(mpUrl + 'utils/canvas-init.js');
const watchWindowResize = ciMod.watchWindowResize || (ciMod.default && ciMod.default.watchWindowResize);
const winHandlers = [];
globalThis.wx = {
  onWindowResize(fn) { winHandlers.push(fn); },
  offWindowResize(fn) { const i = winHandlers.indexOf(fn); if (i >= 0) winHandlers.splice(i, 1); }
};
let resizeFired = 0;
const fakePage = { remeasure: function () { resizeFired++; } };
watchWindowResize(fakePage, fakePage.remeasure);
ok('窗口兜底已挂到 wx.onWindowResize', winHandlers.length === 1);
winHandlers[0]();
ok('窗口尺寸变化会触发重测', resizeFired === 1);
watchWindowResize(fakePage, fakePage.remeasure);
ok('同一页面重复挂不会注册两次', winHandlers.length === 1);
fakePage.onUnload();
ok('页面卸载时摘掉 handler', winHandlers.length === 0);
delete globalThis.wx;

// 自定义 tabBar 的坑（2026-11-17 真机连踩四次，最后一次改成结构方案）：
//  1. app.json 的 custom-tab-bar 自动组件是**每个 tab 页各一份实例**，新实例第一帧
//     只能用声明初值渲染 → 切换时必然闪（亮错一格或整颗消失）。改成页面内自绘。
//  2. wx.showTabBar 会把原生 tabBar 唤醒，和自定义条同时显示 → 谁都不许调。
const capsuleJs = readFileSync(join(mp, 'components/tab-capsule/index.js'), 'utf8');
const shellJs = readFileSync(join(mp, 'custom-tab-bar/index.js'), 'utf8');
const shellWxml = readFileSync(join(mp, 'custom-tab-bar/index.wxml'), 'utf8');

ok('custom-tab-bar 只剩空壳（真正的胶囊由页面渲染）',
  !/wx:for|<view|wx:if/.test(shellWxml));
ok('胶囊组件的下标来自页面（properties.active）', /active:\s*\{\s*type:\s*Number/.test(capsuleJs));
ok('胶囊点击走 wx.switchTab', /wx\.switchTab\s*\(/.test(capsuleJs));
ok('没有任何页面再依赖 getTabBar（那套推送是闪的根源）',
  walk(mp).filter((f) => f.endsWith('.js')).every((f) => !/getTabBar\s*\(/.test(readFileSync(f, 'utf8'))));

let tabApiCalls = [];
for (const f of walk(mp)) {
  if (!f.endsWith('.js')) continue;
  if (/wx\.(hide|show)TabBar\s*\(/.test(readFileSync(f, 'utf8'))) {
    tabApiCalls.push(f.replace(mp + '\\', ''));
  }
}
ok('没有任何文件调用 wx.hideTabBar / wx.showTabBar', tabApiCalls.length === 0, tabApiCalls.join(', '));

// 四个 tab 页：wxml 里渲染胶囊，js 里 tabIdx 与 app.json 的 tabBar.list 顺序一致
const appRoutes = (appJson.tabBar.list || []).map((x) => String(x.pagePath));
const tabPages = ['index', 'weekly', 'monthly', 'impact'];
for (let i = 0; i < tabPages.length; i++) {
  const p = tabPages[i];
  const wxml = readFileSync(join(mp, 'pages', p, p + '.wxml'), 'utf8');
  const js = readFileSync(join(mp, 'pages', p, p + '.js'), 'utf8');
  ok('页面渲染胶囊（' + p + '）', /<tab-capsule\b/.test(wxml));
  ok('页面 tabIdx 与 tabBar 顺序一致（' + p + '）',
    new RegExp('tabIdx:\\s*' + i + '\\b').test(js) && appRoutes[i] === 'pages/' + p + '/' + p,
    'tabIdx 应为 ' + i + '，app.json 第 ' + i + ' 项是 ' + appRoutes[i]);
}

// 胶囊里的 ROUTES 是 tab 顺序的第二份真源（第一份是 app.json.tabBar.list），
// 只校验 tabIdx 不够 —— 哪天加第五个 tab，胶囊会 switchTab 到错页。
const capsuleRoutes = ((capsuleJs.match(/ROUTES\s*=\s*\[([\s\S]*?)\]/) || [, ''])[1]
  .match(/'[^']+'/g) || []).map((x) => x.slice(1, -1));
const listRoutes = (appJson.tabBar.list || []).map((x) => '/' + String(x.pagePath));
ok('胶囊 ROUTES 与 app.json tabBar.list 一致',
  capsuleRoutes.length === listRoutes.length && capsuleRoutes.every((p, i) => p === listRoutes[i]),
  capsuleRoutes.join(' / ') + ' vs ' + listRoutes.join(' / '));

// 皮肤：每个页面的根节点都必须挂主题类，且 theme 初值同步读盘 ——
// 否则浅色用户进到漏挂的页面就是深色（follow 页曾漏过），深色用户第一帧闪浅色。
for (const page of appJson.pages) {
  const name = page.split('/')[1];
  const wxml = readFileSync(join(mp, 'pages', name, name + '.wxml'), 'utf8');
  const js = readFileSync(join(mp, 'pages', name, name + '.js'), 'utf8');
  ok('页面根节点挂了主题类（' + name + '）', /class="wrap[^"]*t-\{\{theme\}\}/.test(wxml));
  ok('theme 初值同步读盘（' + name + '）', /theme:\s*skin\.get\(\)/.test(js));
}

// page 节点没有皮肤类，background: var(--bg) 只会解析成深色基础板
const pageBlock = (readFileSync(join(mp, 'app.wxss'), 'utf8').match(/^page \{[\s\S]*?\}/m) || [''])[0];
ok('page 自身不铺主题底色（否则浅色皮会先闪一帧深色）',
  !/background:\s*var\(--bg\)/.test(pageBlock), pageBlock.slice(0, 60));

// 空闲预载：tab 页第一次切过去才创建，那一帧要解析的数据模块太重。
// 预载逻辑放在 utils/preload.js，由概览页 onReady（首帧之后）触发，app.js 只做兜底。
const preloadJs = readFileSync(join(mp, 'utils/preload.js'), 'utf8');
const needPreload = ['./data/weekly.js', './data/monthly.js', './data/impacts.js', './data/basemap.js', './utils/chart.js'];
const missPreload = needPreload.filter((m) => preloadJs.indexOf(m.replace('./', "../")) < 0);
ok('utils/preload.js 预载了各 tab 页的重模块', missPreload.length === 0, missPreload.join(', '));
ok('预载只在首帧之后触发（概览 onReady + app.js 兜底）',
  /preloadTabModules\(\)/.test(readFileSync(join(mp, 'pages/index/index.js'), 'utf8')) &&
  /setTimeout\(preload\.preloadTabModules/.test(readFileSync(join(mp, 'app.js'), 'utf8')));

// 窗口底色必须跟默认皮肤一致：app.json 里是深色时代的值时，页面内容画出来之前
// 会先闪一帧深色（浅色皮上就是「闪一下再空白」）。默认皮是浅色，静态值也得是浅色。
const winCfg = appJson.window || {};
ok('app.json 窗口底色与默认(浅色)皮肤一致', String(winCfg.backgroundColor).toLowerCase() === '#f4f5f7',
  String(winCfg.backgroundColor));
ok('app.json 导航栏与默认(浅色)皮肤一致',
  String(winCfg.navigationBarBackgroundColor).toLowerCase() === '#f4f5f7' && winCfg.navigationBarTextStyle === 'black',
  winCfg.navigationBarBackgroundColor + ' / ' + winCfg.navigationBarTextStyle);

// 图高与图宽：宽屏下 rpx 会放大 1.45 倍，图表和位图都要封顶
ok('CPC 回归图不超过原图 720px',
  /\.figmap\s*\{[^}]*max-width:\s*720px/.test(readFileSync(join(mp, 'pages/impact/impact.wxss'), 'utf8')));
for (const p of ['weekly', 'monthly', 'fan', 'impact']) {
  const css = readFileSync(join(mp, 'pages', p, p + '.wxss'), 'utf8');
  ok('图表高度在宽屏封顶（' + p + '）', /height:\s*min\(\s*\d+rpx\s*,\s*\d+px\s*\)/.test(css));
}

// ═══════════════════════════════════════════ 汇总

console.log('\n' + '─'.repeat(56));
if (fail === 0) {
  console.log(`✓ 全部通过：${pass} 项检查`);
} else {
  console.log(`✗ ${fail} 项失败 / 共 ${pass + fail} 项\n`);
  for (const f of failures) console.log('  ✗ ' + f);
  process.exit(1);
}
