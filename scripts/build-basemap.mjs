// 生成简化世界陆地底图（Natural Earth 110m），输出等经纬度投影的 SVG path d 字符串。
// 用法：node scripts/build-basemap.mjs
// 输出：data/processed/basemap.txt   （"M x y L x y ... Z" 拼接，viewBox = 0 0 360 180）
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const rawDir = path.join(root, 'data', 'raw');
const outDir = path.join(root, 'data', 'processed');
fs.mkdirSync(rawDir, { recursive: true });
fs.mkdirSync(outDir, { recursive: true });

const cacheFile = path.join(rawDir, 'ne_110m_land.geojson');
const urls = [
  'https://cdn.jsdelivr.net/gh/nvkelso/natural-earth-vector@master/geojson/ne_110m_land.geojson',
  'https://unpkg.com/world-atlas@2/land-110m.json'
];

let geojson;
if (fs.existsSync(cacheFile) && fs.statSync(cacheFile).size > 10000) {
  geojson = JSON.parse(fs.readFileSync(cacheFile, 'utf8'));
} else {
  for (const u of urls) {
    try {
      const res = await fetch(u);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const text = await res.text();
      if (!text.trim().startsWith('{')) throw new Error('not geojson');
      geojson = JSON.parse(text);
      fs.writeFileSync(cacheFile, text);
      console.log(`下载底图：${u}（${(text.length / 1024).toFixed(0)} KB）`);
      break;
    } catch (e) {
      console.warn(`跳过 ${u}：${e.message}`);
    }
  }
}
if (!geojson) { console.error('✗ 未能获取底图数据'); process.exit(1); }

// ---- 工具 ----
const shoelace = (ring) => {
  let a = 0;
  for (let i = 0, n = ring.length; i < n; i++) {
    const [x1, y1] = ring[i], [x2, y2] = ring[(i + 1) % n];
    a += x1 * y2 - x2 * y1;
  }
  return a / 2;
};

// Douglas–Peucker（在经纬度平面上简化）
function simplify(pts, eps) {
  if (pts.length < 3) return pts;
  const [x1, y1] = pts[0], [x2, y2] = pts[pts.length - 1];
  const dx = x2 - x1, dy = y2 - y1;
  const len = Math.hypot(dx, dy) || 1e-9;
  let idx = -1, max = 0;
  for (let i = 1; i < pts.length - 1; i++) {
    const d = Math.abs(dy * pts[i][0] - dx * pts[i][1] + x2 * y1 - y2 * x1) / len;
    if (d > max) { max = d; idx = i; }
  }
  if (max <= eps) return [pts[0], pts[pts.length - 1]];
  return [...simplify(pts.slice(0, idx + 1), eps).slice(0, -1), ...simplify(pts.slice(idx), eps)];
}

const EPS = 0.28;       // 简化容差（度）
const MIN_AREA = 6;     // 小于该面积（平方度）的岛直接丢掉
const ROUND = 0.1;      // 坐标保留精度

const rings = [];
const collect = (geom) => {
  const polys = geom.type === 'Polygon' ? [geom.coordinates]
    : geom.type === 'MultiPolygon' ? geom.coordinates : [];
  for (const poly of polys) {
    // 外环 = 第 0 个；简单起见只画外环（110m 数据基本没有内湖）
    const ring = poly[0];
    if (!ring || ring.length < 4) continue;
    if (Math.abs(shoelace(ring)) < MIN_AREA) continue;
    rings.push(ring);
  }
};
for (const f of geojson.features ?? []) if (f.geometry) collect(f.geometry);

let totalPoints = 0, keptPoints = 0;
const parts = [];
for (const ring of rings) {
  totalPoints += ring.length;
  // 闭合环首尾点相同，会让 DP 退化成两点直线：先去掉尾点，按开放折线简化，最后用 Z 闭合
  let pts = ring.map(([lon, lat]) => [lon, lat]);
  const a = pts[0], b = pts[pts.length - 1];
  if (pts.length > 2 && a[0] === b[0] && a[1] === b[1]) pts = pts.slice(0, -1);
  const simp = simplify(pts, EPS);
  keptPoints += simp.length;
  let d = '';
  let px = null, py = null;
  for (const [lon, lat] of simp) {
    const x = +(lon + 180).toFixed(1);
    const y = +(90 - lat).toFixed(1);
    if (x === px && y === py) continue;
    d += (d ? 'L' : 'M') + x + ' ' + y;
    px = x; py = y;
  }
  if (d) parts.push(d + 'Z');
}

const pathData = parts.join('');
fs.writeFileSync(path.join(outDir, 'basemap.txt'), pathData, 'utf8');
console.log(`✓ 陆地多边形 ${rings.length} 个，顶点 ${totalPoints} → ${keptPoints}`);
console.log(`✓ data/processed/basemap.txt  ${(pathData.length / 1024).toFixed(1)} KB`);
