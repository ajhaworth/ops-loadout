// ---- core ---- DOM-free on purpose: the node check evals exactly this block. ----

// Tiny recursive-descent reader for the Python literal in dcc.py. Not eval: the file
// ends with an `if __name__` block that imports bpy, and we only want the data above it.
function parsePy(text){
  const start = text.indexOf('[', text.indexOf('keyconfig_data'));
  if(start < 0) throw new Error('no keyconfig_data in this file');
  const stop = text.indexOf('if __name__');
  const s = text.slice(start, stop < 0 ? text.length : stop);
  let i = 0;
  const err = m => { throw new Error(m + ' at char ' + i + ': …' + s.slice(Math.max(0,i-30), i+30) + '…'); };
  const skip = () => { for(;;){ while(i < s.length && /\s/.test(s[i])) i++;
                                if(s[i] === '#'){ while(i < s.length && s[i] !== '\n') i++; continue; } break; } };
  function str(q){
    i++; let out = '';
    while(i < s.length && s[i] !== q){
      if(s[i] === '\\'){ const c = s[++i]; out += c === 'n' ? '\n' : c === 't' ? '\t' : c; i++; }
      else out += s[i++];
    }
    if(s[i] !== q) err('unterminated string'); i++; return out;
  }
  function seq(close){                                 // ( ) and [ ] both become arrays
    i++; const out = [];
    for(;;){ skip(); if(s[i] === close){ i++; return out; }
             out.push(value()); skip();
             if(s[i] === ','){ i++; continue; }
             if(s[i] === close){ i++; return out; }
             err('expected , or ' + close); }
  }
  function braced(){                                 // { } is a dict, unless the first item has no ':' —
    i++; skip();                                     // then it's a set literal, e.g. ("mesh_select_mode", {'VERT'})
    if(s[i] === '}'){ i++; return {}; }
    const first = value(); skip();
    const set = s[i] !== ':';
    const out = set ? [first] : {};
    if(!set){ i++; out[first] = value(); skip(); }
    for(;;){ if(s[i] === ','){ i++; skip(); }
             if(s[i] === '}'){ i++; return out; }
             const k = value(); skip();
             if(set){ out.push(k); continue; }
             if(s[i] !== ':') err('expected :'); i++;
             out[k] = value(); skip(); }
  }
  function value(){
    skip(); const c = s[i];
    if(c === '[') return seq(']');
    if(c === '(') return seq(')');
    if(c === '{') return braced();
    if(c === "'" || c === '"') return str(c);
    if(s.startsWith('True', i)){ i += 4; return true; }
    if(s.startsWith('False', i)){ i += 5; return false; }
    if(s.startsWith('None', i)){ i += 4; return null; }
    if(s.startsWith('set()', i)){ i += 5; return []; }  // empty set, e.g. ("delimit", set())
    const m = /^-?\d+(\.\d+)?([eE][-+]?\d+)?/.exec(s.slice(i));
    if(m){ i += m[0].length; return parseFloat(m[0]); }
    err('unexpected token');
  }
  const data = value(); skip();
  if(i < s.length) err('trailing junk');
  return data;
}

const MODS = ['shift','ctrl','alt','oskey'];

const CONTEXTS = {                                     // ordered most specific first = Blender handler priority
  'Viewport: Object':     ['Object Mode','Object Non-modal','3D View','3D View Generic','Screen','Window'],
  'Viewport: Edit Mesh':  ['Mesh','3D View','3D View Generic','Screen','Window'],
  'Viewport: Edit Curve': ['Curve','3D View','3D View Generic','Screen','Window'],
  'Viewport: Sculpt':     ['Sculpt','3D View','3D View Generic','Screen','Window'],
  'UV Editor':            ['UV Editor','Image','Image Generic','View2D','Screen','Window'],
  'Node Editor':          ['Node Editor','Node Generic','View2D','Screen','Window'],
  'Outliner':             ['Outliner','View2D','Screen','Window'],
  'Properties':           ['Property Editor','View2D Buttons List','Screen','Window'],
  'File / Asset Browser': ['File Browser Main','File Browser','Screen','Window'],
  'Transform (modal)':    ['Transform Modal Map'],
  'Bevel (modal)':        ['Bevel Modal Map'],
  'Knife (modal)':        ['Knife Tool Modal Map'],
  'Fly / Walk (modal)':   ['View3D Walk Modal','View3D Fly Modal'],
};

const title = s => s.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());

function friendly(idname, props, modal){
  if(modal) return title(idname.toLowerCase());                       // modal "idname" is an event: CONFIRM
  if(idname === 'wm.call_menu' || idname === 'wm.call_menu_pie' || idname === 'wm.call_panel')
    return title(String(props.name || '').replace(/^[A-Z0-9]+_[A-Z]{2}_/, '').toLowerCase());
  if(idname.startsWith('wm.context_')){
    const leaf = String(props.data_path || props.data_path_iter || '').split('.').pop();
    return title(leaf || idname.split('.').pop()) + (props.value !== undefined ? ' = ' + props.value : '');
  }
  if(idname === 'transform.translate' && props.cursor_transform) return 'Move Cursor';
  return title(idname.split('.').slice(1).join(' ') || idname);
}

function index(data){                                  // -> {keymaps, byName, nItems}
  const keymaps = data.map(([name, meta, contents]) => {
    const km = { name, space: meta.space_type || 'EMPTY', modal: !!meta.modal, bindings: [] };
    for(const [idname, ev, extra] of (contents.items || [])){
      const props = {};
      if(extra && extra.properties) for(const [k, v] of extra.properties) props[k] = v;
      km.bindings.push({ km, idname, ev, props,
                         active: !(extra && extra.active === false),
                         name: friendly(idname, props, km.modal) });
    }
    return km;
  });
  const byName = {}; for(const k of keymaps) byName[k.name] = k;
  return { keymaps, byName, nItems: keymaps.reduce((n, k) => n + k.bindings.length, 0) };
}

// A modifier flag is: absent/false = must not be held, true = must be held,
// anything else (-1, "any state" in newer Blender) or ev.any = don't care.
function modOk(ev, m, held){
  const r = ev[m];
  if(ev.any || r === -1) return true;
  return !!r === !!held[m];
}
const matchMods = (ev, held) => MODS.every(m => modOk(ev, m, held));

const sig = b => [b.ev.type, b.ev.value, b.ev.direction, b.ev.key_modifier,
                  ...MODS.map(m => b.ev[m] ? 1 : 0), b.ev.any ? 1 : 0].join('|');

// Every binding of the context, in priority order, with `shadowed` set when an
// earlier *active* binding already claimed the identical event.
function lookup(ctx, type, held){
  const seen = new Set(), out = [];
  for(const b of ctx){
    if(b.ev.type !== type || !matchMods(b.ev, held)) continue;
    const s = sig(b), shadowed = seen.has(s);
    if(b.active) seen.add(s);
    out.push(Object.assign({ shadowed }, b));
  }
  return out;
}

const KEYLABEL = { LEFTMOUSE:'LMB', MIDDLEMOUSE:'MMB', RIGHTMOUSE:'RMB', BUTTON4MOUSE:'Mouse4',
  BUTTON5MOUSE:'Mouse5', WHEELUPMOUSE:'Wheel↑', WHEELDOWNMOUSE:'Wheel↓',
  WHEELINMOUSE:'WheelIn', WHEELOUTMOUSE:'WheelOut', WHEELLEFTMOUSE:'Wheel←',
  WHEELRIGHTMOUSE:'Wheel→', ACCENT_GRAVE:'`', LEFT_BRACKET:'[', RIGHT_BRACKET:']',
  SEMI_COLON:';', QUOTE:"'", COMMA:',', PERIOD:'.', SLASH:'/', BACK_SLASH:'\\', MINUS:'-', EQUAL:'=',
  RET:'Enter', BACK_SPACE:'Backspace', DEL:'Delete', PAGE_UP:'PgUp', PAGE_DOWN:'PgDn',
  UP_ARROW:'↑', DOWN_ARROW:'↓', LEFT_ARROW:'←', RIGHT_ARROW:'→',
  ONE:'1', TWO:'2', THREE:'3', FOUR:'4', FIVE:'5', SIX:'6', SEVEN:'7', EIGHT:'8', NINE:'9', ZERO:'0',
  ESC:'Esc', SPACE:'Space', TAB:'Tab', OSKEY:'OS', APP:'Menu' };
const keyLabel = t => KEYLABEL[t] || (t && t.length <= 2 ? t : title((t || '').toLowerCase()));

const VALSUF = { PRESS:'', CLICK:' click', CLICK_DRAG:' drag', DOUBLE_CLICK:' double', RELEASE:' release', ANY:' any' };

function chord(ev, osname){
  const p = [];
  if(ev.any) p.push('Any');
  else { if(ev.ctrl) p.push('Ctrl'); if(ev.shift) p.push('Shift'); if(ev.alt) p.push('Alt'); if(ev.oskey) p.push(osname || 'OS'); }
  if(ev.key_modifier) p.push(keyLabel(ev.key_modifier));
  p.push(keyLabel(ev.type));
  return p.join('+') + (VALSUF[ev.value] || '') + (ev.direction ? ' ' + ev.direction.toLowerCase() : '');
}

const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
const propStr = p => Object.entries(p).map(([k, v]) => k + '=' + v).join(', ');
const haystack = (b, osname) => [b.idname, b.name, b.km.name, chord(b.ev, osname), propStr(b.props)].join(' ').toLowerCase();

if(typeof module !== 'undefined') module.exports = { parsePy, index, lookup, CONTEXTS, MODS, chord, friendly, matchMods };
// ---- /core ----

// ---------- layout ----------
const BOTTOM = {
  mac: [['LEFT_CTRL','Ctrl',1.25],['LEFT_ALT','Option',1.25],['OSKEY','Cmd',1.5],['SPACE','',7],
        ['OSKEY','Cmd',1.5],['RIGHT_ALT','Option',1.25],['RIGHT_CTRL','Ctrl',1.25]],
  win: [['LEFT_CTRL','Ctrl',1.25],['OSKEY','Win',1.25],['LEFT_ALT','Alt',1.25],['SPACE','',7.5],
        ['RIGHT_ALT','Alt',1.25],['OSKEY','Win',1.25],['APP','Menu',1.25]],
};
const N = s => s.split(' ').map(t => [t, null, 1]);
const MAIN = () => [
  [['ESC','Esc',1],['','',1],...N('F1 F2 F3 F4'),['','',0.5],...N('F5 F6 F7 F8'),['','',0.5],...N('F9 F10 F11 F12')],
  [['ACCENT_GRAVE',null,1],...N('ONE TWO THREE FOUR FIVE SIX SEVEN EIGHT NINE ZERO MINUS EQUAL'),['BACK_SPACE',null,2]],
  [['TAB',null,1.5],...N('Q W E R T Y U I O P LEFT_BRACKET RIGHT_BRACKET'),['BACK_SLASH',null,1.5]],
  [['CAPS_LOCK','Caps',1.75],...N('A S D F G H J K L SEMI_COLON QUOTE'),['RET',null,2.25]],
  [['LEFT_SHIFT','Shift',2.25],...N('Z X C V B N M COMMA PERIOD SLASH'),['RIGHT_SHIFT','Shift',2.75]],
  BOTTOM[plat()],
];
const SIDE = () => [
  [['','',3]],
  N('INSERT HOME PAGE_UP'), N('DEL END PAGE_DOWN'),
  [['','',3]],   // one blank row so Up sits on the Shift row and the arrows on the Ctrl row, like a real board
  [['','',1],['UP_ARROW',null,1],['','',1]],
  N('LEFT_ARROW DOWN_ARROW RIGHT_ARROW'),
];

// event.code -> Blender type
const CODE = { Escape:'ESC', Tab:'TAB', Space:'SPACE', Enter:'RET', Backspace:'BACK_SPACE', Delete:'DEL',
  Insert:'INSERT', Home:'HOME', End:'END', PageUp:'PAGE_UP', PageDown:'PAGE_DOWN', CapsLock:'CAPS_LOCK',
  ArrowUp:'UP_ARROW', ArrowDown:'DOWN_ARROW', ArrowLeft:'LEFT_ARROW', ArrowRight:'RIGHT_ARROW',
  Minus:'MINUS', Equal:'EQUAL', BracketLeft:'LEFT_BRACKET', BracketRight:'RIGHT_BRACKET',
  Backslash:'BACK_SLASH', Semicolon:'SEMI_COLON', Quote:'QUOTE', Comma:'COMMA', Period:'PERIOD',
  Slash:'SLASH', Backquote:'ACCENT_GRAVE', ContextMenu:'APP',
  ShiftLeft:'LEFT_SHIFT', ShiftRight:'RIGHT_SHIFT', ControlLeft:'LEFT_CTRL', ControlRight:'RIGHT_CTRL',
  AltLeft:'LEFT_ALT', AltRight:'RIGHT_ALT', MetaLeft:'OSKEY', MetaRight:'OSKEY' };
'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('').forEach(c => CODE['Key' + c] = c);
['ZERO','ONE','TWO','THREE','FOUR','FIVE','SIX','SEVEN','EIGHT','NINE'].forEach((w, d) => CODE['Digit' + d] = w);
for(let n = 1; n <= 12; n++) CODE['F' + n] = 'F' + n;
const MODKEY = { LEFT_SHIFT:'shift', RIGHT_SHIFT:'shift', LEFT_CTRL:'ctrl', RIGHT_CTRL:'ctrl',
                 LEFT_ALT:'alt', RIGHT_ALT:'alt', OSKEY:'oskey' };

// ---------- state ----------
const $ = s => document.querySelector(s);
const ls = (k, v) => { try { return v === undefined ? localStorage.getItem('km.' + k) : localStorage.setItem('km.' + k, v); } catch(e){ return null; } };
function plat(){ return ls('plat') || (/Mac/i.test(navigator.platform) ? 'mac' : 'win'); }
const osname = () => plat() === 'mac' ? 'Cmd' : 'Win';
let DATA = null, sticky = { shift:0, ctrl:0, alt:0, oskey:0 }, phys = {}, held = new Set(), custom = new Set();
const mods = () => ({ shift: sticky.shift || phys.shift, ctrl: sticky.ctrl || phys.ctrl,
                      alt: sticky.alt || phys.alt, oskey: sticky.oskey || phys.oskey });

function ctxBindings(){
  const names = $('#ctx').value === 'custom'
    ? DATA.keymaps.filter(k => custom.has(k.name)).map(k => k.name)
    : (CONTEXTS[$('#ctx').value] || []);
  return names.flatMap(n => (DATA.byName[n] || { bindings: [] }).bindings);  // missing names skipped silently
}

// ---------- boot ----------
fetch('portable/scripts/presets/keyconfig/dcc.py')
  .then(r => r.ok ? r.text() : Promise.reject(r.status))
  .then(load)
  .catch(e => { $('#stat').textContent = 'no dcc.py fetched: ' + e; });

function load(text){
  if(!text.includes('keyconfig_data')){ $('#err').textContent = 'that is not a keymap preset (no keyconfig_data): pick portable/scripts/presets/keyconfig/dcc.py'; return; }
  try { DATA = index(parsePy(text)); }
  catch(e){ $('#err').textContent = 'parse failed: ' + e.message; return; }
  $('#err').textContent = '';
  $('#stat').textContent = DATA.keymaps.length + ' keymaps · ' + DATA.nItems + ' items · dcc.py';
  buildCustom(); drawBoard(); render();
}

// ---------- chrome ----------
$('#ctx').innerHTML = Object.keys(CONTEXTS).map(k => '<option>' + k + '</option>').join('') +
                      '<option value="custom">Custom…</option>';
$('#ctx').value = ls('ctx') || 'Viewport: Object';
if(!$('#ctx').value) $('#ctx').value = 'Viewport: Object';
$('#ctx').onchange = () => { ls('ctx', $('#ctx').value); render(); };
$('#plat').value = plat();
$('#plat').onchange = () => { ls('plat', $('#plat').value); $('#osbtn').textContent = osname(); drawBoard(); render(); };
$('#osbtn').textContent = osname();
document.querySelectorAll('button.mod').forEach(b =>
  b.onclick = () => { sticky[b.dataset.mod] = !sticky[b.dataset.mod]; render(); });
$('#q').oninput = render;
$('#q').onkeydown = e => { if(e.key === 'Escape'){ $('#q').value = ''; $('#q').blur(); render(); } e.stopPropagation(); };

function buildCustom(){
  const bySpace = {};
  for(const k of DATA.keymaps) (bySpace[k.space] = bySpace[k.space] || []).push(k.name);
  $('#custom').innerHTML = Object.keys(bySpace).sort().map(sp =>
    '<h4>' + esc(sp) + '</h4>' + bySpace[sp].map(n =>
      '<label><input type=checkbox value="' + esc(n) + '"> ' + esc(n) + '</label>').join('')).join('');
  let saved = []; try { saved = JSON.parse(ls('custom') || '[]'); } catch(e){}
  saved.forEach(n => custom.add(n));
  $('#custom').querySelectorAll('input').forEach(i => {
    i.checked = custom.has(i.value);
    i.onchange = () => { i.checked ? custom.add(i.value) : custom.delete(i.value);
                         ls('custom', JSON.stringify([...custom]));
                         $('#ctx').value = 'custom'; ls('ctx', 'custom'); render(); };
  });
}

function drawBoard(){
  const html = rows => rows.map(r => '<div class=row>' + r.map(([t, lab, w]) =>
    !t ? '<div class="key gap" style="--w:' + w + '"></div>'
       : '<div class="key" data-type="' + t + '" style="--w:' + w + '"><span class=kn>' +
         (lab !== null && lab !== undefined ? lab : keyLabel(t)) + '</span><span class=bn></span><span class=badge></span></div>'
    ).join('') + '</div>').join('');
  $('#keys').innerHTML = '<div style="display:flex;gap:calc(var(--u)*0.35)"><div>' + html(MAIN()) +
                         '</div><div>' + html(SIDE()) + '</div></div>';
  $('#keys').querySelector('[data-type=CAPS_LOCK]').classList.add('dead');   // Blender never binds it
  wire();
}

// ---------- render ----------
function render(){
  if(!DATA) return;
  const m = mods(), ctx = ctxBindings(), q = $('#q').value.trim().toLowerCase();
  document.querySelectorAll('button.mod').forEach(b => b.classList.toggle('on', !!m[b.dataset.mod]));

  const hits = q ? ctx.filter(b => haystack(b, osname()).includes(q)) : [];
  const hitTypes = new Set(hits.map(b => b.ev.type));

  document.querySelectorAll('[data-type]').forEach(el => {
    const t = el.dataset.type, list = lookup(ctx, t, m).filter(b => b.active && !b.shadowed);
    const isMod = MODKEY[t];
    el.classList.toggle('has', !!list.length);
    el.classList.toggle('mod-on', !!(isMod && m[isMod]));
    el.classList.toggle('held', held.has(t));
    el.classList.toggle('hit', q && hitTypes.has(t));
    el.classList.toggle('dim', !!q && !hitTypes.has(t));
    const bn = el.querySelector && el.querySelector('.bn');
    if(bn){
      bn.textContent = list.length ? list[0].name : '';
      el.querySelector('.badge').textContent = list.length > 1 ? list.length : '';
    }
  });

  // mouse text: one line per value, since a button carries several
  $('#mlabels').innerHTML = ['LEFTMOUSE','MIDDLEMOUSE','RIGHTMOUSE'].map(t => {
    const list = lookup(ctx, t, m).filter(b => b.active && !b.shadowed);
    return '<div><b>' + keyLabel(t) + '</b> ' + (list.length
      ? list.map(b => (VALSUF[b.ev.value] || ' press').trim() + ': ' + esc(b.name)).join('<br>')
      : '<span style="opacity:.5">&mdash;</span>') + '</div>';
  }).join('');

  $('#results').innerHTML = !q ? '' : (hits.length ? hits.map((b, n) =>
    row(b, 'data-i=' + n)).join('') : '<div class=hitrow>no match</div>');
  $('#results').querySelectorAll('.hitrow[data-i]').forEach(el => el.onclick = () => {
    const b = hits[el.dataset.i];
    MODS.forEach(k => sticky[k] = b.ev.any ? sticky[k] : (b.ev[k] === true ? 1 : 0));
    phys = {}; render();
    const k = document.querySelector('[data-type="' + b.ev.type + '"]');
    if(k){ k.classList.remove('flash'); void k.offsetWidth; k.classList.add('flash'); }
  });

  // held non-modifier keys: their bindings, plus anything using them as key_modifier (hold D then LMB)
  const hk = [...held].filter(t => !MODKEY[t]);
  $('#detail').innerHTML = hk.map(t => {
    const own = lookup(ctx, t, m);
    const asMod = ctx.filter(b => b.ev.key_modifier === t);
    return '<h5 class=mono>' + keyLabel(t) + '</h5>' + own.concat(asMod).map(b => row(b)).join('');
  }).join('');

  const drawn = new Set([...document.querySelectorAll('[data-type]')].map(e => e.dataset.type));
  const rest = ctx.filter(b => !drawn.has(b.ev.type));
  $('#other').innerHTML = rest.map(b => row(b)).join('') || '<div class=hitrow>none</div>';
  $('#otherwrap').querySelector('summary').textContent =
    'Other events (' + rest.length + ') — trackpad, NDOF, timers, action zones…';
}

function row(b, attr){
  return '<div class=hitrow ' + (attr || '') + '><span class=ch>' + chord(b.ev, osname()) + '</span>' +
    '<span>' + esc(b.name) + (b.active ? '' : ' <i style="opacity:.6">(disabled)</i>') + '</span>' +
    '<span class=id>' + esc(b.idname) + (Object.keys(b.props).length ? ' &nbsp;' + esc(propStr(b.props)) : '') + '</span>' +
    '<span class=km>' + esc(b.km.name) + '</span></div>';
}

// ---------- hover tooltip ----------
const tip = $('#tip');
function wire(){
  document.querySelectorAll('[data-type]').forEach(el => {
    el.onmouseenter = () => showTip(el.dataset.type);
    el.onmouseleave = () => tip.style.display = 'none';
  });
}
document.addEventListener('mousemove', e => {
  if(tip.style.display !== 'block') return;
  const x = Math.min(e.clientX + 16, innerWidth - tip.offsetWidth - 8);
  const y = Math.min(e.clientY + 16, innerHeight - tip.offsetHeight - 8);
  tip.style.left = Math.max(4, x) + 'px'; tip.style.top = Math.max(4, y) + 'px';
});
function showTip(type){
  if(!DATA) return;
  const m = mods(), ctx = ctxBindings();
  const here = lookup(ctx, type, m);
  const other = ctx.filter(b => b.ev.type === type && !matchMods(b.ev, m));
  const line = b => '<div class="b ' + (b.active ? '' : 'off') + (b.shadowed ? ' shadow' : '') + '">' +
    esc(b.name) + ' <span class=mono>' + esc(b.idname) + '</span> ' +
    '<span class=mono>' + esc(b.ev.value || '') + '</span> ' +
    '<span style="color:var(--dim)">' + esc(b.km.name) + '</span>' +
    (Object.keys(b.props).length ? ' <span class=mono>' + esc(propStr(b.props)) + '</span>' : '') +
    (b.active ? '' : ' (disabled)') + (b.shadowed ? ' shadowed' : '') + '</div>';
  tip.innerHTML = '<h5>' + chord({ type, ...m2ev(m) }, osname()) + '</h5>' +
    (here.length ? here.map(line).join('') : '<div class=b style="opacity:.5">nothing bound</div>') +
    (other.length ? '<div class=other><h5>with other modifiers</h5>' +
      other.map(b => '<div class=b><span class=mono>' + chord(b.ev, osname()) + '</span> ' + esc(b.name) + '</div>').join('') +
      '</div>' : '');
  tip.style.display = 'block';
}
const m2ev = m => ({ shift: !!m.shift, ctrl: !!m.ctrl, alt: !!m.alt, oskey: !!m.oskey, value: 'PRESS' });

// ---------- physical keys ----------
addEventListener('keydown', e => {
  if(/^(INPUT|SELECT|BUTTON|TEXTAREA)$/.test(document.activeElement.tagName)) return;  // let our own controls keep Tab/arrows/Space
  const t = CODE[e.code]; if(!t) return;
  e.preventDefault();
  if(MODKEY[t]) phys[MODKEY[t]] = 1; else held.add(t);
  render();
});
addEventListener('keyup', e => {
  const t = CODE[e.code]; if(!t) return;
  if(MODKEY[t]) phys[MODKEY[t]] = 0; else held.delete(t);
  render();
});
const clear = () => { phys = {}; held.clear(); render(); };
addEventListener('blur', clear);
document.addEventListener('visibilitychange', clear);
