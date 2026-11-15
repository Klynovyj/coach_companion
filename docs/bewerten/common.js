// Gemeinsame Bausteine der Bewertungsseiten (Spieler + Trainer).
const CC = (() => {
  const SUPABASE_URL = 'https://ujrpsqfekmmjxypsdyza.supabase.co';
  const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVqcnBzcWZla21tanh5cHNkeXphIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI4MjQwNDIsImV4cCI6MjEwODQwMDA0Mn0.37Ht9fqrnmIqS23qNNM81zRr-zPFc8K6pjiUMmUmvFg';

  const token = new URLSearchParams(location.hash.slice(1)).get('t') ||
    new URLSearchParams(location.search).get('t') || '';

  async function rpc(fn, body) {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: SUPABASE_ANON, Authorization: `Bearer ${SUPABASE_ANON}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
  }

  /** Logos/Fotos (Stufe 62); bei Fehler leeres Objekt – die Seite bleibt nutzbar. */
  async function media(matchId) {
    try {
      const m = await rpc('rating_media', { p_token: token, p_match_id: matchId || '' });
      return m && m.ok ? m : {};
    } catch (e) {
      return {};
    }
  }

  /** Profil des Link-Inhabers (Stufe 63): Foto + eigene Abgaben. */
  async function profile() {
    try {
      const p = await rpc('rating_profile', { p_token: token });
      return p && p.ok ? p : null;
    } catch (e) {
      return null;
    }
  }

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const safeImg = (u) => (typeof u === 'string' && /^data:image\/(png|jpe?g|webp|gif);base64,/.test(u) ? u : null);

  function fmtDate(iso, withTime) {
    if (!iso) return '';
    const opts = { weekday: 'short', day: '2-digit', month: '2-digit' };
    if (withTime) Object.assign(opts, { hour: '2-digit', minute: '2-digit' });
    return new Date(iso).toLocaleString('de-DE', opts);
  }
  const f1 = (x) => (x == null ? '–' : Number(x).toFixed(1).replace('.', ','));
  const initials = (n) => String(n || '?').split(/\s+/).filter(Boolean).map((w) => w[0]).slice(0, 2).join('').toUpperCase();

  function crest(logo, name) {
    const src = safeImg(logo);
    return `<div class="crest">${src ? `<img src="${src}" alt="">` : `<span class="ini">${esc(initials(name))}</span>`}</div>`;
  }

  function avatar(p, photos) {
    const src = safeImg(photos?.[p.id]);
    return `<div class="ava"><div class="ph">${src ? `<img src="${src}" alt="" loading="lazy">` : `<span class="ini">${esc(initials(p.name))}</span>`}</div>` +
      (p.number != null ? `<div class="nr">${esc(p.number)}</div>` : '') + '</div>';
  }

  /** Profil-Karte: Foto, Name, Rolle und Fortschritt der offenen Abgaben. */
  function profileCard(prof, fallbackName, role) {
    const name = prof?.name || fallbackName || '';
    const src = safeImg(prof?.photo);
    const open = (prof?.entries || []).filter((e) => e.open);
    const done = open.filter((e) => e.done).length;
    const ring = open.length
      ? `<div class="ring" style="--p:${(done / open.length) * 100}"><div><span>${done}/${open.length}<small>bewertet</small></span></div></div>`
      : '';
    return `<div class="me"><div class="ava"><div class="ph">${src ? `<img src="${src}" alt="">` : `<span class="ini">${esc(initials(name))}</span>`}</div></div>
      <div class="mi"><div class="mh">Hallo</div><div class="mn">${esc(name)}</div><div class="mr">${esc(role)}</div></div>${ring}</div>`;
  }

  /** Statuszeile einer eigenen Abgabe (fuer Kacheln und Listen). */
  function entryStatus(e, kind) {
    if (!e) return { cls: 'miss', text: '' };
    if (e.done) {
      if (e.abstained) return { cls: 'ok', text: '✓ nicht da' };
      const st = e.match_stars ? ' ' + '★'.repeat(Math.round(e.match_stars)) : '';
      return { cls: 'ok', text: `✓ bewertet${st}` };
    }
    return e.open ? { cls: 'todo', text: 'offen' } : { cls: 'miss', text: 'verpasst' };
  }

  /** Liste „Deine Abgaben" (Spieler-Seite). */
  function entriesCard(prof, logos, usName) {
    const es = prof?.entries || [];
    if (!es.length) return '';
    return '<div class="card"><h2>Deine Abgaben</h2><p class="sub">Die letzten Spiele, in denen du dabei warst.</p>' + es.map((e) => {
      const parts = String(e.title).match(/^(.*?)\s+–\s+(.*?)\s+\d+:\d+$/) || [];
      const opp = parts[1] ? (parts[1] === usName ? parts[2] : parts[1]) : e.title;
      const s = entryStatus(e);
      const det = e.done ? [
        e.match_stars ? `Spiel ${'★'.repeat(e.match_stars)}` : null,
        e.self_stars ? `Du ${'★'.repeat(e.self_stars)}` : null,
        e.total ? `${e.rated}/${e.total} Mitspieler` : null,
        e.motm ? '👑' : null,
      ].filter(Boolean).join(' · ') : fmtDate(e.match_date);
      return `<div class="mine">${crest(logos?.[e.match_id], opp)}<div class="tx">${esc(e.title)}<small>${esc(det)}</small></div><span class="badge ${s.cls}">${e.done ? '✓' : esc(s.text)}</span></div>`;
    }).join('') + '</div>';
  }

  /** Kopf mit Wappen/Ergebnis. [round] = {title, match_date, closes_at, open}. */
  function scoreboard(m, round) {
    const parts = String(round?.title || '').match(/^(.*?)\s+–\s+(.*?)\s+(\d+):(\d+)$/);
    let home, away, hs, as;
    if (m.us && m.opp) {
      const us = { name: m.us.name, logo: m.us.logo, us: true };
      const them = { name: m.opp.name, logo: m.opp.logo };
      [home, away] = m.home ? [us, them] : [them, us];
      [hs, as] = m.home ? [m.own_score, m.opp_score] : [m.opp_score, m.own_score];
    } else if (parts) {
      home = { name: parts[1] }; away = { name: parts[2] }; hs = parts[3]; as = parts[4];
    } else {
      return `<div class="score"><div class="row3"><div></div><div class="result">${esc(round?.title || '')}</div><div></div></div></div>`;
    }
    const side = (t) => `<div class="side ${t.us ? 'us' : 'them'}">${crest(t.logo, t.name)}<div class="tn">${esc(t.name)}</div></div>`;
    const status = round
      ? (round.open
        ? `<span class="pill open">Offen bis ${esc(fmtDate(round.closes_at, true))} Uhr</span>`
        : '<span class="pill">Bewertung beendet</span>')
      : '';
    return `<div class="score"><div class="row3">${side(home)}<div class="result">${esc(hs ?? '–')}<span>:</span>${esc(as ?? '–')}</div>${side(away)}</div>
      <div class="meta"><span class="pill">${esc(fmtDate(round?.match_date))}</span>${status}</div></div>`;
  }

  /** Spiel-Kacheln (Trainer). rounds = [{match_id,title,match_date,open}], logos = {match_id: dataurl}. */
  function matchTiles(rounds, sel, logos, usName, entries) {
    const byMatch = Object.fromEntries((entries || []).map((e) => [e.match_id, e]));
    if (!rounds || rounds.length < 2) return '';
    return '<div class="tiles">' + rounds.map((r) => {
      const opp = (String(r.title).match(/^(.*?)\s+–\s+(.*?)\s+\d+:\d+$/) || []);
      const oppName = opp[1] ? (opp[1] === usName ? opp[2] : opp[1]) : r.title;
      return `<button class="tile ${r.match_id === sel ? 'on' : ''}" data-m="${esc(r.match_id)}">${crest(logos?.[r.match_id], oppName)}
        <span>${esc(oppName)}<small><span class="dot ${r.open ? '' : 'off'}"></span>${esc(fmtDate(r.match_date))}${byMatch[r.match_id] ? `<span class="stt ${entryStatus(byMatch[r.match_id]).cls}">${esc(entryStatus(byMatch[r.match_id]).text)}</span>` : ''}</small></span></button>`;
    }).join('') + '</div>';
  }

  function starsInput(key, value, cls) {
    let h = `<div class="stars ${cls || ''}" data-key="${esc(key)}" role="radiogroup">`;
    for (let i = 1; i <= 5; i++) h += `<button type="button" data-v="${i}" class="${value >= i ? 'on' : ''}" aria-label="${i} Sterne">★</button>`;
    return h + '</div>';
  }
  function stars(v) {
    const n = Math.max(0, Math.min(5, Math.round(v || 0)));
    return `<span class="st">${'★'.repeat(n)}<i>${'★'.repeat(5 - n)}</i></span>`;
  }

  /** Sterne-Klicks binden; onChange(key, value|null). Nochmal tippen nimmt zurück. */
  function bindStars(root, getValue, onChange) {
    root.querySelectorAll('.stars').forEach((el) => {
      el.addEventListener('click', (e) => {
        const b = e.target.closest('button');
        if (!b) return;
        let v = Number(b.dataset.v);
        if (getValue(el.dataset.key) === v) v = null;
        onChange(el.dataset.key, v);
        el.querySelectorAll('button').forEach((x) => x.classList.toggle('on', v != null && Number(x.dataset.v) <= v));
        b.classList.add('pop');
        setTimeout(() => b.classList.remove('pop'), 140);
        const row = el.closest('.prow');
        if (row) row.classList.toggle('done', v != null);
      });
    });
  }

  function playerRow(p, photos, key, value, sub) {
    return `<div class="prow ${value ? 'done' : ''}">${avatar(p, photos)}<div class="nm">${esc(p.name)}${sub ? `<small>${esc(sub)}</small>` : ''}</div>${starsInput(key, value, 'sm')}</div>`;
  }

  function motmTiles(players, photos, selected) {
    return '<div class="motm">' + players.map((p) =>
      `<button type="button" class="mt ${selected === p.id ? 'on' : ''}" data-motm="${esc(p.id)}">${avatar(p, photos)}<span class="nm">${esc(p.name)}</span></button>`).join('') + '</div>';
  }

  /** Podest (Platz 1–3) aus [{id, votes}] – Gleichstand teilt sich den Platz. */
  function podium(motm, byId, photos) {
    if (!motm || !motm.length) return '<p class="sub" style="text-align:center;color:var(--muted)">Noch keine Stimmen.</p>';
    const ranked = [];
    let place = 0, last = null;
    motm.forEach((m, i) => { if (m.votes !== last) { place = i + 1; last = m.votes; } ranked.push({ ...m, place }); });
    const top = ranked.slice(0, 3);
    const order = [top[1], top[0], top[2]];
    return '<div class="podium">' + order.map((m) => {
      if (!m) return '<div></div>';
      const p = byId[m.id] || { id: m.id, name: 'Unbekannt' };
      const c = 'p' + Math.min(m.place, 3);
      return `<div class="pod ${c}">${avatar(p, photos)}<div class="nm">${esc(p.name)}</div><div class="vt">${m.votes} ${m.votes === 1 ? 'Stimme' : 'Stimmen'}</div><div class="blk">${m.place}</div></div>`;
    }).join('') + '</div>';
  }

  function gradeTiles(tiles) {
    return '<div class="grades">' + tiles.map((t) =>
      `<div class="grade ${t.cls}"><b>${f1(t.avg)}</b>${stars(t.avg)}<span class="lb">${esc(t.label)} · ${t.n} ${t.n === 1 ? 'Note' : 'Noten'}</span></div>`).join('') + '</div>';
  }

  /** Balken je Spieler: rows = [{p, t:{avg,n}|null, m:{avg,n}|null}]. */
  function bars(rows, photos) {
    const line = (cls, label, v) => `<div class="bl ${cls}"><span style="width:76px">${label}</span><div class="trk"><div style="width:${v ? (v.avg / 5) * 100 : 0}%"></div></div><b>${v ? f1(v.avg) + ` <span style="color:var(--muted);font-weight:500">(${v.n})</span>` : '–'}</b></div>`;
    return '<div class="legend"><span><i style="background:var(--green2)"></i>Trainer</span><span><i style="background:var(--gold)"></i>Mannschaft</span></div>' +
      rows.map((r) => `<div class="brow">${avatar(r.p, photos)}<div class="bx"><div class="nm">${esc(r.p.name)}</div>${line('t', 'Trainer', r.t)}${line('m', 'Mannschaft', r.m)}</div></div>`).join('');
  }

  function sortPlayers(ps) {
    return (ps || []).slice().sort((a, b) => (a.number ?? 999) - (b.number ?? 999) || String(a.name).localeCompare(String(b.name)));
  }

  function message(el, icon, title, text) {
    el.innerHTML = `<div class="card msg"><div class="ic">${icon}</div><h2>${esc(title)}</h2><p>${esc(text)}</p></div>`;
  }

  return { profile, profileCard, entriesCard, entryStatus, token, rpc, media, esc, fmtDate, f1, crest, avatar, scoreboard, matchTiles, starsInput, stars, bindStars,
    playerRow, motmTiles, podium, gradeTiles, bars, sortPlayers, message, safeImg };
})();
