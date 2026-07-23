/*
 * Clockwise — custom Lovelace card for Home Assistant
 * ---------------------------------------------------
 * Renders the clock's real 7-segment face (days column, live time, red logo
 * dot, amber divider, D/M/Y) plus compact controls, reading the entities the
 * firmware auto-discovers over MQTT. Nothing to configure in the simple case.
 *
 * Install:
 *   1. Copy this file to  <HA config>/www/clockwise-card.js
 *   2. Settings → Dashboards → (⋮) Resources → Add Resource
 *        URL: /local/clockwise-card.js   Type: JavaScript Module
 *   3. Add a card to a dashboard:
 *        type: custom:clockwise-card
 *      (optional)  prefix: clockwise      # entity_id prefix, default "clockwise"
 *
 * Entities used (created automatically by the clock; the `prefix` is the part
 * after the domain, default "clockwise"):
 *   sensor.<p>_time  _date  _dow  _distance  _rssi
 *   binary_sensor.<p>_presence  _moving  _still
 *   number.<p>_brightness   select.<p>_mode
 *   switch.<p>_logo  _dim    button.<p>_sync  _reboot
 */

const SEG = {'0':'abcdef','1':'bc','2':'abged','3':'abgcd','4':'fgbc','5':'afgcd','6':'afgedc','7':'abc','8':'abcdefg','9':'abcfgd'};
const SEGP = {
  a:'11,3 35,3 38.5,6.5 35,10 11,10 7.5,6.5',
  b:'37,13 40.5,9.5 44,13 44,35 40.5,38.5 37,35',
  c:'37,49 40.5,45.5 44,49 44,71 40.5,74.5 37,71',
  d:'11,74 35,74 38.5,77.5 35,81 11,81 7.5,77.5',
  e:'2,49 5.5,45.5 9,49 9,71 5.5,74.5 2,71',
  f:'2,13 5.5,9.5 9,13 9,35 5.5,38.5 2,35',
  g:'11,38.5 35,38.5 38.5,42 35,45.5 11,45.5 7.5,42'
};
const DAYS = ['MON','TUE','WED','THU','FRI','SAT','SUN'];

// Each logical key may show up in HA under more than one entity-id suffix,
// because HA slugifies the entity's *display name* (e.g. "Displayed time" ->
// _displayed_time) rather than the short key the firmware intended. List every
// suffix a key can wear; the card matches whichever one actually exists.
const ALIASES = {
  time:['time','displayed_time'],
  date:['date','displayed_date'],
  dow:['dow','day_of_week'],
  distance:['distance'],
  rssi:['rssi','wifi_signal'],
  presence:['presence'],
  moving:['moving'],
  still:['still','still_present'],
  brightness:['brightness'],
  mode:['mode'],
  logo:['logo','logo_led'],
  dim:['dim','dim_when_empty'],
  sync:['sync','sync_time'],
  reboot:['reboot'],
  online:['online','connectivity']
};

// Digits render at a fixed design size (h px tall) -- responsiveness comes
// from scaling the WHOLE card as one unit (see the .scalewrap `zoom` rule in
// _build), not from resizing each piece independently. Independently
// clamping just the digit width left everything else (logo dot, colon dots,
// day labels, chip padding) at fixed size, so it visually clashed with the
// shrunk digits instead of shrinking together.
function digitSVG(ch, h) {
  const w = h * 46 / 84, on = SEG[ch] || '';
  let s = `<svg width="${w}" height="${h}" viewBox="0 0 46 84" style="display:block;overflow:visible">`;
  for (const k in SEGP) {
    const lit = on.indexOf(k) >= 0;
    s += `<polygon points="${SEGP[k]}" fill="${lit ? '#f4f6ff' : '#2c3038'}"${lit ? ' style="filter:drop-shadow(0 0 4px rgba(230,238,255,.45))"' : ''}/>`;
  }
  return s + '</svg>';
}
function digitsHTML(num, h) {
  return String(num).split('').map(c => c === ' ' ? `<span style="display:inline-block;width:${h*46/84}px"></span>` : digitSVG(c, h)).join('');
}

class ClockwiseCard extends HTMLElement {
  setConfig(config) {
    this._config = config || {};
    this._prefix = this._config.prefix || 'clockwise';
    this._built = false;
  }
  getCardSize() { return 5; }

  set hass(hass) {
    this._hass = hass;
    this._resolvePrefix();
    if (!this._built) this._build();
    this._update();
  }

  // Figure out the real entity prefix from what HA actually created, so a stale
  // `prefix:` in the card config (or a renamed device) can't break it. We look
  // for the brightness number entity -- its name always matches its key -- and
  // take the prefix from its id. An explicit config prefix is honoured only if
  // it actually resolves; otherwise we auto-detect.
  _resolvePrefix() {
    const st = this._hass ? this._hass.states : {};
    const cfgP = this._config.prefix;
    // A prefix is "good" if its time sensor exists AND has a real value -- this
    // skips orphan/duplicate entities HA may have left behind after a rename.
    const good = p => {
      const t = st[`sensor.${p}_time`] || st[`sensor.${p}_displayed_time`];
      return t && t.state !== 'unknown' && t.state !== 'unavailable' && t.state !== '';
    };
    if (cfgP && good(cfgP)) { this._prefix = cfgP; return; }
    let fallback = null;
    for (const id in st) {
      const m = id.match(/^number\.(.+)_brightness$/);
      if (m) { if (good(m[1])) { this._prefix = m[1]; return; } if (!fallback) fallback = m[1]; }
    }
    this._prefix = fallback || cfgP || 'clockwise';
  }

  // Resolve a logical key to the real entity_id HA created. Tries the detected
  // prefix with each known alias suffix first; if none exist, falls back to any
  // entity in the domain ending with an alias suffix; last resort is the plain
  // prefix+key so nothing throws.
  _eid(domain, key) {
    const st = this._hass ? this._hass.states : {};
    const p = this._prefix, cands = ALIASES[key] || [key];
    for (const a of cands) { const id = `${domain}.${p}_${a}`; if (st[id]) return id; }
    for (const a of cands) {
      const suf = `_${a}`, pre = domain + '.';
      for (const id in st) if (id.startsWith(pre) && id.endsWith(suf)) return id;
    }
    return `${domain}.${p}_${cands[0]}`;
  }
  _state(domain, key) {
    const s = this._hass && this._hass.states[this._eid(domain, key)];
    return s ? s.state : undefined;
  }
  // True only for a real value -- HA reports "unavailable"/"unknown" (as actual
  // state strings, not undefined) when the clock drops off MQTT. Without this,
  // those strings got fed straight into the digit renderer as if they were the
  // time/date, producing a wall of stray blank segment-digits.
  _valid(s) {
    return s !== undefined && s !== 'unavailable' && s !== 'unknown';
  }

  _build() {
    this.innerHTML = `
      <ha-card style="max-width:460px;margin:0 auto">
      <style>
        .cw{--fg:#f4f6ff;--dim:#2c3038;font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
          container-type:inline-size}
        /* The whole card renders at a fixed 460px design size, then this one
           rule scales it down as a single unit to fit a narrower card/window
           -- so the digits, colon, logo dot, day labels and chip padding all
           shrink together in proportion instead of resizing independently
           (which is what caused them to visually clash before). zoom is used
           instead of transform:scale because it participates in layout, so
           the card's actual box shrinks too instead of leaving empty space
           -- Chrome/Edge only, matching this card's other requirements. */
        .cw .scalewrap{zoom:min(1, calc(100cqi / 460px))}
        .cw .panel{background:radial-gradient(130% 130% at 50% 0%,#14161c 0,#030304 78%);padding:14px 16px 10px;border-radius:12px 12px 0 0;overflow-x:auto}
        .cw .top{display:flex;align-items:stretch;gap:8px}
        .cw .dowcol{display:flex;flex-direction:column;justify-content:space-between;padding:2px 0}
        .cw .dowcol span{font-family:ui-monospace,"Consolas","SF Mono","Courier New",monospace;font-size:14px;font-weight:700;letter-spacing:1.5px;color:#31353d;width:46px;height:15px;display:flex;align-items:center;justify-content:center;line-height:1;text-indent:1.5px}
        .cw .dowcol span.on{color:var(--fg);text-shadow:0 0 10px rgba(230,238,255,.65)}
        .cw .time{display:flex;align-items:center;flex:1;justify-content:space-evenly}
        .cw .digits{display:flex;gap:7px}
        .cw .colon{display:flex;flex-direction:column;align-items:center;height:120px;padding:0 3px}
        .cw .colon .logo{width:11px;height:11px;border-radius:50%;background:#26282e;margin-top:3px;flex:0 0 auto;transition:background .2s,box-shadow .2s}
        .cw .colon .logo.on{background:#ff3b3b;box-shadow:0 0 9px 2px rgba(255,59,59,.6)}
        .cw .cdots{flex:1;display:flex;flex-direction:column;justify-content:center;gap:22px}
        .cw .cdots i{width:14px;height:14px;border-radius:50%;background:var(--fg);box-shadow:0 0 12px 2px rgba(230,238,255,.55);animation:cwblink 2s steps(1,end) infinite}
        @keyframes cwblink{0%,50%{opacity:1}50.01%,100%{opacity:.12}}
        /* Blinking implies a live clock -- freeze it dim while the data isn't. */
        .cw.offline .cdots i{animation:none;opacity:.12;box-shadow:none}
        .cw .toast{position:absolute;left:50%;top:10px;transform:translate(-50%,-6px);background:rgba(34,211,238,.16);color:#22d3ee;font-size:12px;font-weight:600;padding:5px 12px;border-radius:16px;box-shadow:inset 0 0 0 1px rgba(34,211,238,.35);opacity:0;pointer-events:none;transition:opacity .2s,transform .2s;z-index:5}
        .cw .toast.show{opacity:1;transform:translate(-50%,0)}
        .cw{position:relative}
        .cw .amber{height:5px;border-radius:3px;background:linear-gradient(90deg,#f5a623,#e8890a);box-shadow:0 0 13px 1px rgba(245,166,35,.4);margin:6px 0 8px}
        .cw .bottom{display:flex;align-items:flex-end;justify-content:space-between;padding:0 2px}
        .cw .grp{display:flex;align-items:flex-end;gap:3px}
        .cw .grp .lab{font-size:13px;font-weight:700;color:#525863;letter-spacing:.06em;padding-bottom:4px}
        .cw .ctl{padding:11px 13px;display:flex;flex-direction:column;gap:9px;background:#101218;border-radius:0 0 12px 12px}
        .cw .status{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
        .cw .pill{display:inline-flex;align-items:center;gap:5px;font-size:11.5px;padding:4px 9px;border-radius:20px;background:#1b1e26;color:#c9cdd6}
        .cw .pill .d{width:7px;height:7px;border-radius:50%;background:#3d4250}
        .cw .pill .d.g{background:#34d399;box-shadow:0 0 6px #34d399}
        .cw .pill .d.r{background:#fb7185;box-shadow:0 0 6px #fb7185}
        .cw .row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
        .cw .row .lbl{font-size:11.5px;color:#8a8f98;width:34px;flex:0 0 auto}
        .cw input[type=range]{flex:1 1 60px;min-width:60px;-webkit-appearance:none;appearance:none;height:6px;border-radius:4px;background:#23262f;outline:none}
        .cw input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:15px;height:15px;border-radius:50%;background:#22d3ee;cursor:pointer;box-shadow:0 0 0 4px rgba(34,211,238,.15)}
        .cw input[type=range]::-moz-range-thumb{width:15px;height:15px;border:none;border-radius:50%;background:#22d3ee;cursor:pointer}
        .cw .seg{display:flex;background:#1b1e26;border-radius:8px;padding:2px;gap:2px;max-width:190px;flex:0 0 auto}
        .cw .seg b{flex:1;text-align:center;font-size:11.5px;font-weight:600;padding:5px 6px;border-radius:6px;color:#8a8f98;cursor:pointer}
        .cw .seg b.on{background:#22d3ee;color:#04121a}
        .cw .chips{display:flex;gap:6px}
        .cw .chip{flex:1;display:flex;align-items:center;justify-content:center;gap:5px;font-size:11.5px;font-weight:600;padding:7px 4px;border-radius:8px;background:#1b1e26;color:#8a8f98;cursor:pointer;user-select:none}
        .cw .chip.on{background:rgba(34,211,238,.14);color:#22d3ee;box-shadow:inset 0 0 0 1px rgba(34,211,238,.3)}
        .cw .chip.warn{color:#fb7185}
      </style>
      <div class="cw">
        <div class="toast" id="cw-toast"></div>
        <div class="scalewrap">
        <div class="panel">
          <div class="top">
            <div class="dowcol">${DAYS.map(d => `<span data-day="${d}">${d}</span>`).join('')}</div>
            <div class="time">
              <div class="digits" id="cw-h"></div>
              <div class="colon"><span class="logo" id="cw-logo"></span><div class="cdots"><i></i><i></i></div></div>
              <div class="digits" id="cw-m"></div>
            </div>
          </div>
          <div class="amber"></div>
          <div class="bottom">
            <div class="grp"><div class="digits" id="cw-d"></div><span class="lab">D</span></div>
            <div class="grp"><div class="digits" id="cw-mo"></div><span class="lab">M</span></div>
            <div class="grp"><div class="digits" id="cw-y"></div><span class="lab">Y</span></div>
          </div>
        </div>
        <div class="ctl">
          <div class="status" id="cw-status"></div>
          <div class="row"><span class="lbl">Bright</span>
            <input type="range" min="0" max="100" id="cw-bright">
            <div class="seg" id="cw-mode">
              <b data-mode="manual">Man</b><b data-mode="schedule">Sched</b><b data-mode="sun">Sun</b>
            </div>
          </div>
          <div class="chips">
            <span class="chip" id="cw-logo-chip">💡 Logo</span>
            <span class="chip" id="cw-dim-chip">🌙 Dim empty</span>
            <span class="chip" id="cw-sync">↻ Sync</span>
            <span class="chip warn" id="cw-reboot">⟳ Reboot</span>
          </div>
        </div>
        </div>
      </div>
      </ha-card>`;

    // listeners
    const bright = this.querySelector('#cw-bright');
    bright.addEventListener('change', e =>
      this._call('number', 'set_value', this._eid('number', 'brightness'), { value: Number(e.target.value) }));
    this.querySelectorAll('#cw-mode b').forEach(b =>
      b.addEventListener('click', () =>
        this._call('select', 'select_option', this._eid('select', 'mode'), { option: b.dataset.mode })));
    this.querySelector('#cw-logo-chip').addEventListener('click', () =>
      this._toggle('logo'));
    this.querySelector('#cw-dim-chip').addEventListener('click', () =>
      this._toggle('dim'));
    this.querySelector('#cw-sync').addEventListener('click', () => {
      this._call('button', 'press', this._eid('button', 'sync'));
      this._flash('↻ Sync sent');
    });
    this.querySelector('#cw-reboot').addEventListener('click', () => {
      this._call('button', 'press', this._eid('button', 'reboot'));
      this._flash('⟳ Rebooting…');
    });

    this._built = true;
  }

  // Brief on-card confirmation text (momentary buttons have no state to show).
  _flash(msg) {
    const t = this.querySelector('#cw-toast');
    if (!t) return;
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(this._flashT);
    this._flashT = setTimeout(() => t.classList.remove('show'), 1600);
  }

  _call(domain, service, entity_id, data) {
    if (!this._hass) return;
    this._hass.callService(domain, service, Object.assign({ entity_id }, data || {}));
  }
  _toggle(key) {
    const on = this._state('switch', key) === 'on';
    this._call('switch', on ? 'turn_off' : 'turn_on', this._eid('switch', key));
  }

  _update() {
    const q = id => this.querySelector(id);

    // time "H:MM" -- blank (not garbage digits) while the sensor is unavailable
    const timeState = this._state('sensor', 'time');
    // Freeze the blinking colon (it implies a live clock) once the data is
    // stale -- prefer the explicit `online` entity, fall back to "does the
    // time sensor have a real value" if that entity isn't set up.
    const onlineState = this._state('binary_sensor', 'online');
    const offline = onlineState !== undefined ? onlineState !== 'on' : !this._valid(timeState);
    q('.cw').classList.toggle('offline', offline);
    const t = this._valid(timeState) ? timeState.split(':') : [];
    q('#cw-h').innerHTML = digitsHTML(t[0] || '', 120);
    q('#cw-m').innerHTML = digitsHTML(t[1] || '', 120);

    // date "YYYY-MM-DD"
    const dateState = this._state('sensor', 'date');
    const dparts = this._valid(dateState) ? dateState.split('-') : [];
    const yr = dparts[0] || '', mo = dparts[1] ? String(Number(dparts[1])) : '', dd = dparts[2] || '';
    q('#cw-d').innerHTML = digitsHTML(dd, 58);
    q('#cw-mo').innerHTML = digitsHTML(mo, 58);
    q('#cw-y').innerHTML = digitsHTML(yr, 58);

    // day of week (1=Mon..7=Sun)
    const dowState = this._state('sensor', 'dow');
    const dow = this._valid(dowState) ? Number(dowState) : 0;
    this.querySelectorAll('.dowcol span').forEach((s, i) =>
      s.classList.toggle('on', i === dow - 1));

    // logo dot
    q('#cw-logo').classList.toggle('on', this._state('switch', 'logo') === 'on');

    // status pills
    const pres = this._state('binary_sensor', 'presence') === 'on';
    const mov = this._state('binary_sensor', 'moving') === 'on';
    const stl = this._state('binary_sensor', 'still') === 'on';
    const dist = this._state('sensor', 'distance');
    const rssi = this._state('sensor', 'rssi');
    const presTxt = pres ? (mov ? 'Present · moving' : (stl ? 'Present · still' : 'Present')) : 'Clear';
    // connection indicator -- reflects HA reachability (the `online` entity goes
    // offline via MQTT last-will if the clock drops off, even when the clock
    // itself still runs).
    let pills = '';
    if (onlineState !== undefined)
      pills += `<span class="pill"><span class="d ${onlineState === 'on' ? 'g' : 'r'}"></span>${onlineState === 'on' ? 'Connected' : 'Offline'}</span>`;
    pills += `<span class="pill"><span class="d ${pres ? 'g' : ''}"></span>${presTxt}</span>`;
    if (pres && this._valid(dist)) pills += `<span class="pill">📏 ${dist} m</span>`;
    if (this._valid(rssi)) pills += `<span class="pill">📶 ${rssi} dBm</span>`;
    q('#cw-status').innerHTML = pills;

    // brightness (don't fight an active drag)
    const bright = q('#cw-bright');
    const bv = this._state('number', 'brightness');
    if (this._valid(bv) && document.activeElement !== bright) bright.value = bv;

    // mode
    const mode = this._state('select', 'mode');
    this.querySelectorAll('#cw-mode b').forEach(b =>
      b.classList.toggle('on', b.dataset.mode === mode));

    // logo / dim chips
    q('#cw-logo-chip').classList.toggle('on', this._state('switch', 'logo') === 'on');
    q('#cw-dim-chip').classList.toggle('on', this._state('switch', 'dim') === 'on');
  }
}

customElements.define('clockwise-card', ClockwiseCard);
window.customCards = window.customCards || [];
window.customCards.push({
  type: 'clockwise-card',
  name: 'Clockwise Clock',
  description: 'Recreates the Clockwise 7-segment face with live data and controls.'
});
console.info('%c CLOCKWISE-CARD %c loaded ', 'background:#22d3ee;color:#04121a;font-weight:700', 'color:#22d3ee');
