'use strict';
// The page side of the editor. Swift loads SVG text in, this file shows it,
// hit-tests clicks, recolours shapes and hands serialized SVG back.

const SVGNS = 'http://www.w3.org/2000/svg';
const INK = 'http://www.inkscape.org/namespaces/inkscape';
const stage = document.getElementById('stage');
const box = document.getElementById('sel');
const msg = document.getElementById('msg');

// Elements that never paint directly, so they stay out of the tree and the palette.
const SKIP = new Set(['defs', 'metadata', 'title', 'desc', 'style', 'script', 'clipPath', 'mask',
  'pattern', 'linearGradient', 'radialGradient', 'symbol', 'marker', 'filter', 'namedview']);
const SHAPES = new Set(['path', 'rect', 'circle', 'ellipse', 'polygon', 'polyline', 'line',
  'text', 'tspan', 'textPath', 'use', 'image']);
const CONTAINERS = new Set(['g', 'a', 'switch']);
const UNIT = { '': 1, px: 1, mm: 96 / 25.4, cm: 96 / 2.54, in: 96, pt: 96 / 72, pc: 16 };

let root = null;          // the live <svg>, imported into this page
let selected = null;
let addedViewBox = false; // we add one for display when the file has none; never saved
let prefix = '';          // text before the root tag (XML declaration, doctype, comments)
let commitTimer = null;

function send(name, obj) {
  window.webkit.messageHandlers[name].postMessage(JSON.stringify(obj));
}

// ---------- loading ----------

function parseLen(s) {
  const m = /^\s*([0-9.eE+-]+)\s*([a-z%]*)\s*$/.exec(s || '');
  if (!m || !(m[2] in UNIT)) return null;
  const v = parseFloat(m[1]);
  return v > 0 ? { v, unit: m[2] || 'px', px: v * UNIT[m[2]] } : null;
}

function intrinsic() {
  const w = parseLen(root.getAttribute('width')), h = parseLen(root.getAttribute('height'));
  const vb = root.hasAttribute('viewBox') ? root.viewBox.baseVal : null;
  const hasVB = vb && vb.width > 0 && vb.height > 0;
  let pw, ph;
  if (w && h) { pw = w.px; ph = h.px; }
  else if (hasVB && w) { pw = w.px; ph = w.px * vb.height / vb.width; }
  else if (hasVB && h) { ph = h.px; pw = h.px * vb.width / vb.height; }
  else if (hasVB) { pw = vb.width; ph = vb.height; }
  else { const b = root.getBBox(); pw = b.width || 300; ph = b.height || 150; }
  const unit = (w && h && w.unit === h.unit) ? w.unit : 'px';
  return { width: pw, height: ph, unit,
           physWidth: unit === 'px' ? pw : w.v, physHeight: unit === 'px' ? ph : h.v };
}

function load(text, path) {
  clearTimeout(commitTimer); commitTimer = null;
  const doc = new DOMParser().parseFromString(text, 'image/svg+xml');
  const el = doc.documentElement;
  if (doc.getElementsByTagName('parsererror').length || el.localName !== 'svg' || el.namespaceURI !== SVGNS) {
    root = null; stage.replaceChildren(); select(null);
    msg.textContent = 'This file could not be read as SVG.'; msg.style.display = 'flex';
    send('error', { message: 'This file could not be read as SVG.' });
    return;
  }
  msg.style.display = 'none';
  const i = text.search(/<svg[\s>]/);
  prefix = i > 0 ? text.slice(0, i) : '';
  root = document.importNode(el, true);
  stage.replaceChildren(root);
  const info = intrinsic();
  addedViewBox = false;
  if (!root.hasAttribute('viewBox')) {
    const w = parseLen(root.getAttribute('width')), h = parseLen(root.getAttribute('height'));
    if (w && h) root.setAttribute('viewBox', `0 0 ${w.px} ${h.px}`);
    else { const b = root.getBBox(); root.setAttribute('viewBox', `${b.x} ${b.y} ${b.width || 300} ${b.height || 150}`); }
    addedViewBox = true;
  }
  send('loaded', Object.assign(info, { tree: tree(root), palette: palette() }));
  select(path ? nodeAt(path) : null);
}

// ---------- structure ----------

function pathOf(el) {
  const p = [];
  for (; el && el !== root; el = el.parentNode) p.unshift(Array.prototype.indexOf.call(el.parentNode.children, el));
  return p;
}

function nodeAt(p) {
  let el = root;
  for (const i of p) el = el && el.children[i];
  return el && el !== root ? el : null;
}

function skipped(el) {
  for (; el && el !== root; el = el.parentNode) if (SKIP.has(el.localName) || el.namespaceURI !== SVGNS) return true;
  return false;
}

const isLayer = el => el.getAttributeNS(INK, 'groupmode') === 'layer';

function nameOf(el) {
  const label = el.getAttributeNS(INK, 'label');
  if (label) return label;
  if (el.id) return el.id;
  if (el.localName === 'text') return `text “${el.textContent.trim().slice(0, 24)}”`;
  return el.localName;
}

function tree(parent) {
  const out = [];
  for (const c of parent.children) {
    if (c.namespaceURI !== SVGNS || SKIP.has(c.localName)) continue;
    const node = { path: pathOf(c), name: nameOf(c), tag: c.localName, layer: isLayer(c) };
    if (CONTAINERS.has(c.localName)) {
      const kids = tree(c);
      if (kids.length) node.children = kids;
    } else if (!SHAPES.has(c.localName)) continue;
    else node.swatch = hex(getComputedStyle(c).fill);
    out.push(node);
  }
  return out;
}

// Every painted shape the selection covers: the shape itself, or everything inside a group.
function shapesIn(el) {
  const all = [el, ...el.querySelectorAll('*')];
  return all.filter(e => SHAPES.has(e.localName) && !skipped(e));
}

// ---------- colour ----------

function hex(c) {
  if (!c || c === 'none') return 'none';
  if (c.startsWith('url')) return 'gradient';
  const m = /rgba?\(([^)]+)\)/.exec(c);
  if (!m) return c;
  const p = m[1].split(/[\s,\/]+/).filter(Boolean).map(parseFloat);
  if (p.length > 3 && p[3] === 0) return 'none';
  return '#' + p.slice(0, 3).map(v => Math.round(v).toString(16).padStart(2, '0')).join('').toUpperCase();
}

function palette() {
  const counts = new Map();
  for (const el of root.querySelectorAll('*')) {
    if (!SHAPES.has(el.localName) || skipped(el)) continue;
    const cs = getComputedStyle(el);
    for (const c of [cs.fill, cs.stroke]) {
      const h = hex(c);
      if (h.startsWith('#')) counts.set(h, (counts.get(h) || 0) + 1);
    }
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1]).map(e => e[0]);
}

// Write a presentation attribute and drop any inline-style copy so the file stays
// tidy (fill="#4B9CD3", as typed). If the file has stylesheet rules, those beat
// attributes, so the value also goes into the inline style.
function setPaint(el, name, value) {
  if (el.style.getPropertyValue(name)) el.style.removeProperty(name);
  if (el.getAttribute('style') === '') el.removeAttribute('style');
  el.setAttribute(name, value);
  if (root.querySelector('style') || el.hasAttribute('class')) el.style.setProperty(name, value);
}

function setColor(prop, value) {
  if (!selected) return;
  for (const el of shapesIn(selected)) setPaint(el, prop, value);
  changed();
}

function setOpacity(prop, value) {
  if (!selected) return;
  const v = String(Math.round(value * 1000) / 1000);
  for (const el of shapesIn(selected)) setPaint(el, prop + '-opacity', v);
  changed();
}

function changed() {
  drawBox();
  send('selected', selected ? info(selected) : null);
  clearTimeout(commitTimer);
  commitTimer = setTimeout(commit, 300);
}

function commit() {
  clearTimeout(commitTimer); commitTimer = null;
  if (root) send('changed', { text: serialize(), palette: palette(), tree: tree(root) });
}

// ---------- selection ----------

function info(el) {
  const shapes = shapesIn(el);
  const first = shapes[0] || el;
  const cs = getComputedStyle(first);
  const distinct = prop => new Set(shapes.map(s => hex(getComputedStyle(s)[prop]))).size > 1;
  const ancestors = [];
  for (let a = el.parentNode; a && a !== root; a = a.parentNode) ancestors.unshift({ path: pathOf(a), name: nameOf(a) });
  let layer = null;
  for (let a = el; a && a !== root; a = a.parentNode) if (isLayer(a)) { layer = nameOf(a); break; }
  return {
    path: pathOf(el), tag: el.localName, name: nameOf(el), layer,
    isGroup: !SHAPES.has(el.localName), shapeCount: shapes.length,
    fill: hex(cs.fill), stroke: hex(cs.stroke),
    fillOpacity: parseFloat(cs.getPropertyValue('fill-opacity')) || 0,
    strokeOpacity: parseFloat(cs.getPropertyValue('stroke-opacity')) || 0,
    mixedFill: distinct('fill'), mixedStroke: distinct('stroke'),
  };
}

function select(el) {
  selected = el;
  drawBox();
  send('selected', el ? info(el) : null);
}

function selectPath(p) { select(nodeAt(p)); }

function selectParent() {
  if (selected && selected.parentNode && selected.parentNode !== root) select(selected.parentNode);
}

function drawBox() {
  if (!selected) { box.style.display = 'none'; return; }
  const r = selected.getBoundingClientRect();
  Object.assign(box.style, {
    display: 'block',
    left: (r.left + scrollX - 3) + 'px', top: (r.top + scrollY - 3) + 'px',
    width: (r.width + 6) + 'px', height: (r.height + 6) + 'px',
  });
}

// The browser's own hit-testing gives the topmost painted shape and honours
// fill-rule evenodd, so holes in compound paths click through to what is below.
// Option-click steps down through everything stacked under the pointer.
stage.addEventListener('mousedown', e => {
  if (!root || e.button !== 0) return;
  const hits = document.elementsFromPoint(e.clientX, e.clientY)
    .filter(h => h !== root && root.contains(h) && SHAPES.has(h.localName));
  if (!hits.length) { select(null); return; }
  let pick = hits[0];
  if (e.altKey && selected) pick = hits[(hits.indexOf(selected) + 1) % hits.length];
  select(pick);
});
stage.addEventListener('dblclick', selectParent);
document.addEventListener('keydown', e => { if (e.key === 'Escape') select(null); });
window.addEventListener('resize', drawBox);
window.addEventListener('scroll', drawBox);

function setBackground(mode) { document.body.className = mode; }

// ---------- output ----------

function serialize() {
  const clone = root.cloneNode(true);
  if (addedViewBox) clone.removeAttribute('viewBox');
  return prefix + new XMLSerializer().serializeToString(clone) + '\n';
}

// The SVG with an explicit pixel size, so it is drawn at full resolution rather than scaled up.
function svgAt(w, h) {
  const clone = root.cloneNode(true);
  clone.setAttribute('width', w);
  clone.setAttribute('height', h);
  return new XMLSerializer().serializeToString(clone);
}

async function rasterize(w, h, bg) {
  const url = URL.createObjectURL(new Blob([svgAt(w, h)], { type: 'image/svg+xml' }));
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    const canvas = document.createElement('canvas');
    canvas.width = w; canvas.height = h;
    const g = canvas.getContext('2d');
    if (bg) { g.fillStyle = bg; g.fillRect(0, 0, w, h); }
    g.drawImage(img, 0, 0, w, h);
    return canvas.toDataURL('image/png').slice('data:image/png;base64,'.length);
  } finally {
    URL.revokeObjectURL(url);
  }
}

// Turns any CSS colour (names, hsl(), ...) into rgb()/rgba(), or '' if it is not one.
function normalizeColor(s) {
  if (!CSS.supports('color', s)) return '';
  const probe = document.createElement('div');
  probe.style.color = s;
  document.body.appendChild(probe);
  const c = getComputedStyle(probe).color;
  probe.remove();
  return c;
}

send('ready', {});
