// 报告自检：在 Node 里用最小 DOM/Canvas 桩执行页面的内联脚本，
// 抓运行时错误、NaN 坐标、空表格，并模拟缩放/平移/点击等交互。
// 用法：node scripts/verify-report.mjs [页面路径]
//   默认 report/enso_dashboard.html，也可以校验发布副本：node scripts/verify-report.mjs docs/index.html
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const arg = process.argv[2];
const file = arg ? path.resolve(process.cwd(), arg) : path.join(root, 'report', 'enso_dashboard.html');
const html = fs.readFileSync(file, 'utf8');
console.log(`校验文件：${path.relative(root, file) || file}\n`);

const script = html.match(/<script>([\s\S]*?)<\/script>/);
if (!script) { console.error('✗ 未找到内联 <script> 块'); process.exit(1); }

const problems = [];
const bad = [];
const calls = { fillRect: 0, lineTo: 0, moveTo: 0, fill: 0, stroke: 0, fillText: 0 };
const seenText = [];

const numCheck = (name, args) => {
  for (const a of args) {
    if (typeof a === 'number' && !Number.isFinite(a)) bad.push(`${name}(${args.join(',')})`);
  }
};

function makeCtx() {
  const rec = (name) => (...args) => {
    if (calls[name] !== undefined) calls[name]++;
    if (name === 'fillText' && typeof args[0] === 'string') seenText.push(args[0]);
    numCheck(name, args);
  };
  const target = {
    font: '', textBaseline: '', textAlign: '', strokeStyle: '', fillStyle: '', lineWidth: 1,
    setTransform: rec('setTransform'), clearRect: rec('clearRect'), beginPath: rec('beginPath'),
    moveTo: rec('moveTo'), lineTo: rec('lineTo'), stroke: rec('stroke'), fill: rec('fill'),
    closePath: rec('closePath'), fillRect: rec('fillRect'), fillText: rec('fillText'),
    arc: rec('arc'), rect: rec('rect'), roundRect: rec('roundRect'),
    measureText: (t) => ({ width: String(t).length * 6 }),
    setLineDash: (a) => numCheck('setLineDash', a)
  };
  return new Proxy(target, { get: (t, k) => (k in t ? t[k] : () => {}) });
}

// 事件桩：记录监听器，便于在 Node 里模拟滚轮/点击
const listen = (el) => {
  el.ls = el.ls || {};
  el.addEventListener = (type, fn) => { (el.ls[type] = el.ls[type] || []).push(fn); };
  return el;
};
const fire = (el, type, ev) => {
  const e = Object.assign({ preventDefault() {}, stopPropagation() {}, deltaY: 0, clientX: 0, clientY: 0 }, ev);
  ((el && el.ls && el.ls[type]) || []).forEach(fn => fn(e));
};

const els = new Map();
const getEl = (key) => {
  if (!els.has(key)) {
    els.set(key, listen({
      key, innerHTML: '', textContent: '', src: '', style: {},
      attrs: {}, clientWidth: 900, clientHeight: 260, width: 0, height: 0,
      getContext: () => makeCtx(),
      getBoundingClientRect() { return { left: 0, top: 0, width: this.clientWidth, height: this.clientHeight }; },
      setAttribute(k, v) { this.attrs[k] = v; },
      classList: { add() {}, remove() {} }
    }));
  }
  return els.get(key);
};

const qa = new Map();
const documentStub = {
  getElementById: (id) => getEl(id),
  querySelector: (sel) => getEl(sel),
  // 年数按钮是页面里真实存在的 <button data-years=…>，这里按同样的结构造出来以便模拟点击
  querySelectorAll: (sel) => {
    if (!qa.has(sel)) {
      const years = /spanWeekly/.test(sel) ? ['1', '3', '5', '10', '20', '0']
        : /spanMonthly/.test(sel) ? ['1', '5', '10', '30', '0']
          : [];
      qa.set(sel, years.map(y => listen({
        dataset: { years: y }, clientWidth: 0, clientHeight: 0,
        classList: { add() {}, remove() {} }
      })));
    }
    return qa.get(sel);
  },
  addEventListener() {}
};
const windowStub = listen({ devicePixelRatio: 1 });
const locationStub = { reload() {} };

try {
  new Function('window', 'document', 'location', script[1])(windowStub, documentStub, locationStub);
} catch (e) {
  console.error('✗ 页面脚本运行报错：' + e.message);
  console.error(e.stack.split('\n').slice(0, 4).join('\n'));
  process.exit(1);
}

// 行数统计：兼容 <tr> 与带属性的 <tr class="rv" style="…">（新版逐行揭示会给行加属性）
const rows = (sel) => ((getEl(sel).innerHTML.match(/<tr[\s>]/g) ?? []).length);
const checks = [
  ['周指数表行数 ≥ 8', rows('#tblWeekly tbody') >= 8, rows('#tblWeekly tbody')],
  ['概率表行数 ≥ 9', rows('#tblProb tbody') >= 9, rows('#tblProb tbody')],
  ['RONI 分位表行数 ≥ 9', rows('#tblFcst tbody') >= 9, rows('#tblFcst tbody')],
  ['数据源表行数 ≥ 10', rows('#tblSrc tbody') >= 10, rows('#tblSrc tbody')],
  ['指标卡片已渲染', getEl('cards').innerHTML.includes('Niño3.4'), ''],
  ['官方结论已渲染', (getEl('synopsis').textContent || '').length > 20, ''],
  ['柱状图有绘制', calls.fillRect > 100, calls.fillRect],
  ['折线有绘制', calls.lineTo > 200, calls.lineTo],
  ['坐标轴标签有绘制', calls.fillText > 10, calls.fillText],
  ['无 NaN / Infinity 坐标', bad.length === 0, bad.slice(0, 5).join(' | ')],
  ['影响区色块 ≥ 13（DJF）', (getEl('zoneLayer').innerHTML.match(/class="zone/g) ?? []).length >= 13,
    (getEl('zoneLayer').innerHTML.match(/class="zone/g) ?? []).length],
  ['影响区编号标记 ≥ 13', (getEl('markerLayer').innerHTML.match(/class="marker"/g) ?? []).length >= 13,
    (getEl('markerLayer').innerHTML.match(/class="marker"/g) ?? []).length],
  ['影响区表行数 ≥ 13', rows('#tblImpact tbody') >= 13, rows('#tblImpact tbody')],
  ['陆地底图已注入', (getEl('landPath').attrs.d || '').length > 5000, ((getEl('landPath').attrs.d || '').length / 1024).toFixed(1) + ' KB'],
  ['Niño3.4 框已标注', /Niño3\.4\s+[+-]/.test(getEl('nino34Label').textContent || ''), getEl('nino34Label').textContent],
  ['回归图已内嵌（温度）', String(getEl('imgTemp').src).startsWith('data:image/png;base64,'), String(getEl('imgTemp').src).slice(0, 22)],
  ['回归图已内嵌（降水）', String(getEl('imgPrec').src).startsWith('data:image/png;base64,'), String(getEl('imgPrec').src).slice(0, 22)]
];

// ---- 交互模拟：滚轮缩放 / 单击定位 / 双击复位 ----
const cvW = getEl('cvWeekly');
const readout = () => getEl('rangeWeekly').textContent || '';
const pts = (s) => { const m = /（(\d+) \/ (\d+) 点）/.exec(s); return m ? +m[1] : -1; };

const full = pts(readout());
if (process.env.ENSO_DEBUG) {
  console.log('DEBUG listeners:', Object.keys(cvW.ls || {}),
    'wheel:', ((cvW.ls || {}).wheel || []).length,
    'click:', ((cvW.ls || {}).click || []).length,
    'clientWidth:', cvW.clientWidth, 'rectW:', cvW.getBoundingClientRect().width);
}
fire(cvW, 'wheel', { clientX: 500, deltaY: -240 });
const zoomed = pts(readout());
if (process.env.ENSO_DEBUG) console.log('DEBUG readout after wheel:', readout());
fire(cvW, 'click', { clientX: 500 });
const clicked = readout();
fire(cvW, 'dblclick', {});
const reset = pts(readout());

// 拖动平移：必须先放大（全区间时无法平移），再按住向左拖 → 窗口前移
fire(cvW, 'dblclick', {});
fire(cvW, 'wheel', { clientX: 500, deltaY: -240 });   // 先放大
const beforePan = readout();
fire(cvW, 'mousedown', { clientX: 600 });
fire(cvW, 'mousemove', { clientX: 300 });             // 向左拖 = 看更早的数据
fire(windowStub, 'mouseup', {});
const afterPan = readout();
const panMoved = beforePan !== afterPan;
fire(cvW, 'click', { clientX: 600 });                 // 拖动之后紧跟的 click 应被忽略
const clickAfterDragIgnored = !/▍选中/.test(readout());

// 复位按钮（回到默认年数窗口）
fire(getEl('resetWeekly'), 'click', {});
const afterResetBtn = pts(readout());

// 年数窗口按钮：1 年 / 全部
const spanBtns = documentStub.querySelectorAll('#spanWeekly button');
const btnByYears = (y) => spanBtns.find(b => b.dataset.years === String(y));
fire(btnByYears(1), 'click', {});
const oneYear = pts(readout());
const oneYearTxt = readout();
fire(btnByYears(0), 'click', {});
const allYears = pts(readout());

// 月度图：默认 10 年 / 全部（1950 年起）
const mReadout = () => getEl('rangeMonthly').textContent || '';
const mBtns = documentStub.querySelectorAll('#spanMonthly button');
const monthlyDefault = pts(mReadout());
fire(mBtns.find(b => b.dataset.years === '0'), 'click', {});
const monthlyAll = pts(mReadout());

checks.push(
  ['默认窗口 = 3 年（≈157 周）', full > 140 && full < 175, full + ' 点'],
  ['年数按钮数量 = 6', spanBtns.length === 6, spanBtns.map(b => b.dataset.years + '年').join(' / ')],
  ['「1 年」窗口 ≈ 52 周', oneYear > 44 && oneYear < 60, oneYear + ' 点'],
  ['「全部」窗口 = 完整历史', allYears > 2000, allYears + ' 点'],
  ['窗口读数含起止日期', /^窗口 \d{4}-\d{2}-\d{2} → \d{4}-\d{2}-\d{2}/.test(oneYearTxt), oneYearTxt.slice(0, 40)],
  ['滚轮可缩放时间轴', zoomed > 0 && zoomed < full, `${full} → ${zoomed} 点`],
  ['单击显示选中日期', /▍选中 \d{4}-\d{2}-\d{2}/.test(clicked), (clicked.match(/▍选中 [\d-]+/) || [''])[0]],
  ['双击复位到默认窗口', reset === full, `${zoomed} → ${reset} 点`],
  ['拖动可平移时间轴', panMoved, afterPan.slice(0, 30)],
  ['拖动后 click 不误触发定位', clickAfterDragIgnored, ''],
  ['复位按钮回默认窗口', afterResetBtn === full, afterResetBtn + ' 点'],
  ['月度默认窗口 = 10 年（≈120 月）', monthlyDefault > 110 && monthlyDefault < 130, monthlyDefault + ' 点'],
  ['月度「全部」= 1950 年起', monthlyAll > 850, monthlyAll + ' 点'],
  ['标题写明数据跨度', /1981-\d\d-\d\d/.test(getEl('hintWeekly').textContent || '') &&
    /1950-01/.test(getEl('hintMonthly').textContent || ''), getEl('hintWeekly').textContent]
);

checks.push(
  ['页脚作者信息完整', /彭桢燃/.test(html) && /中国地质大学（武汉）/.test(html) && /TVGG/.test(html), ''],
  ['页脚邮箱为可点击链接', /mailto:zhenran\.peng@cug\.edu\.cn/.test(html), ''],
  ['页脚含 GitHub 主页链接', /href="https:\/\/github\.com\/pengzhenran"/.test(html), ''],
  ['页脚不含 CGU 报告页链接', !/cgu-2026-reports\/"/.test(html), ''],
  ['课题组二维码已内嵌', String(getEl('qrImg').src).startsWith('data:image/jpeg;base64,'),
    String(getEl('qrImg').src).slice(0, 26)],
  ['二维码有文字说明', /课题组公众号/.test(html), '']
);

let failed = 0;
for (const [name, ok, detail] of checks) {
  if (!ok) failed++;
  console.log(`${ok ? '✓' : '✗'} ${name}${detail !== '' && detail !== undefined ? '  → ' + detail : ''}`);
}
console.log(`\n绘制调用统计：fillRect=${calls.fillRect} lineTo=${calls.lineTo} stroke=${calls.stroke} fillText=${calls.fillText}`);
console.log(`文件大小：${(html.length / 1024).toFixed(1)} KB，内联数据 ${(script[1].length / 1024).toFixed(1)} KB`);
process.exit(failed ? 1 : 0);
