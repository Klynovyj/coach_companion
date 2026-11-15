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
  /**
   * Abzeichen setzen: Spieler des Spiels (Zwischenstand, ggf. mehrere) und
   * Spieler des Monats. Ändert nur die Platzhalter – Eingaben bleiben erhalten.
   */
  function applyBadges(b) {
    const motm = new Set((b?.motm || []).map((x) => x.id));
    const motmFinal = !!b?.motm_final;
    const pomIds = new Set(b?.pom?.ids || []);
    const pomFinal = !!b?.pom?.final;
    const html = (id) => (motm.has(id)
      ? `<span class="bd s ${motmFinal ? '' : 'pre'}" title="${motmFinal ? 'Gewählt' : 'Aktueller Stand der Wahl'}">👑 ${motmFinal ? '' : 'voraussichtl. '}Spieler des Spiels</span>` : '') +
      (pomIds.has(id)
        ? `<span class="bd m ${pomFinal ? '' : 'pre'}" title="${pomFinal ? 'Von allen Trainern gekürt' : 'Platz 1 der Monats-Rangliste'}">🏆 ${pomFinal ? '' : 'voraussichtl. '}Spieler des Monats</span>` : '');
    const pom = { has: (id) => pomIds.has(id) };
    document.querySelectorAll('[data-bdg]').forEach((el) => {
      const id = el.dataset.bdg;
      const h = html(id);
      if (el.innerHTML !== h) el.innerHTML = h;
      el.closest('.prow, .me')?.classList.toggle('hon', h !== '');
    });
    document.querySelectorAll('[data-bdg-mini]').forEach((el) => {
      const id = el.dataset.bdgMini;
      el.textContent = (motm.has(id) ? '👑' : '') + (pom.has(id) ? '🏆' : '');
    });
  }

  function profileCard(prof, fallbackName, role, selfId) {
    const name = prof?.name || fallbackName || '';
    const src = safeImg(prof?.photo);
    const open = (prof?.entries || []).filter((e) => e.open);
    const done = open.filter((e) => e.done).length;
    const ring = open.length
      ? `<div class="ring" style="--p:${(done / open.length) * 100}"><div><span>${done}/${open.length}<small>bewertet</small></span></div></div>`
      : '';
    return `<div class="me"><div class="ava"><div class="ph">${src ? `<img src="${src}" alt="">` : `<span class="ini">${esc(initials(name))}</span>`}</div></div>
      <div class="mi"><div class="mh">Hallo</div><div class="mn">${esc(name)}</div><div class="mr">${esc(role)}</div>${selfId ? `<div class="bdgs" data-bdg="${esc(selfId)}"></div>` : ''}</div>${ring}</div>`;
  }

  /** Statuszeile einer eigenen Abgabe (fuer Kacheln und Listen). */
  function entryStatus(e, kind) {
    if (!e) return { cls: 'miss', text: '' };
    if (e.done) {
      if (e.abstained) return { cls: 'ok', text: '✓ nicht da' };
      const st = e.match_stars ? ' ' + starText(e.match_stars) : '';
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
        e.match_stars ? `Spiel ${starText(e.match_stars)}` : null,
        e.self_stars ? `Du ${starText(e.self_stars)}` : null,
        e.total ? `${e.rated}/${e.total} Mitspieler` : null,
        e.motm ? '👑' : null,
      ].filter(Boolean).join(' · ') : fmtDate(e.match_date);
      return `<div class="mine">${crest(logos?.[e.match_id], opp)}<div class="tx">${esc(e.title)}<small>${esc(det)}</small></div><span class="badge ${s.cls}">${e.done ? '✓' : esc(s.text)}</span></div>`;
    }).join('') + '</div>';
  }

  const MONTHS = ['Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'];
  /** „2026-11" → „November 2026" (kurz: „Nov 26"). */
  function monthLabel(ym, short) {
    const [y, m] = String(ym || '').split('-').map(Number);
    if (!y || !m) return ym || '';
    return short ? `${MONTHS[m - 1].slice(0, 3)} ${String(y).slice(2)}` : `${MONTHS[m - 1]} ${y}`;
  }

  /** Große Karte des gekürten Spielers des Monats. */
  function monthCard(h, ym) {
    if (!h) {
      return `<div class="card month"><div class="lbl">Spieler des Monats · ${esc(monthLabel(ym))}</div><p class="none">Noch nicht gekürt.</p></div>`;
    }
    const p = { id: h.id, name: h.name || 'Unbekannt', number: h.number };
    return `<div class="card month"><div class="lbl">Spieler des Monats</div><div class="crown">👑</div>
      ${avatar(p, { [h.id]: h.photo })}<div class="nm">${esc(p.name)}</div><div class="mo">${esc(monthLabel(h.year_month))}</div></div>`;
  }

  /**
   * Karte „Spieler des Monats" mit Zustimmung aller Trainer: fest gekürt oder
   * voraussichtlich (Platz 1 der Rangliste) + wer schon bestätigt hat.
   */
  function crownCard(month) {
    const c = month?.crown || {};
    const ym = month?.year_month;
    const byId = Object.fromEntries((month?.ranking || []).map((r) => [r.id, r]));
    const req = c.required || [];
    const name = (id) => byId[id]?.name || (month?.honored?.id === id ? month.honored.name : 'Unbekannt');
    const photo = (id) => byId[id]?.photo || (month?.honored?.id === id ? month.honored.photo : null);
    let head;
    if (c.crowned) {
      const p = { id: c.crowned, name: name(c.crowned), number: byId[c.crowned]?.number };
      head = `<div class="lbl">Spieler des Monats · ${esc(monthLabel(ym))}</div><div class="crown">👑</div>
        ${avatar(p, { [p.id]: photo(p.id) })}<div class="nm">${esc(p.name)}</div><div class="mo">Von allen Trainern bestätigt</div>`;
    } else if ((c.leaders || []).length) {
      const ls = c.leaders.map((id) => ({ id, name: name(id), number: byId[id]?.number }));
      head = `<div class="lbl">Spieler des Monats · ${esc(monthLabel(ym))}</div>
        <div class="avs">${ls.slice(0, 4).map((p) => avatar(p, { [p.id]: photo(p.id) })).join('')}</div>
        <div class="prov">Voraussichtlich</div><div class="names">${esc(ls.map((p) => p.name).join(' · '))}</div>
        <div class="mo">Noch nicht von allen Trainern bestätigt</div>`;
    } else {
      head = `<div class="lbl">Spieler des Monats · ${esc(monthLabel(ym))}</div><p class="none">Noch keine Trainer-Noten.</p>`;
    }
    const counts = c.counts || {};
    const best = Object.entries(counts).sort((a, b) => b[1] - a[1])[0];
    const conf = req.length ? `<div class="conf">
      ${best ? `<div style="font-size:13px;color:var(--muted)">Zustimmung für <b style="color:var(--gold)">${esc(name(best[0]))}</b>: ${best[1]}/${req.length} Trainer</div>
        <div class="bar2"><div style="width:${(best[1] / req.length) * 100}%"></div></div>` : `<div style="font-size:13px;color:var(--muted)">Noch keine Zustimmung – gekürt wird erst, wenn alle ${req.length} Trainer denselben Spieler bestätigen.</div>`}
      ${req.map((r) => `<div class="cr"><b>${esc(r.name)}${r.rater_id === month.me ? ' (du)' : ''}</b>${r.player_id ? `<span class="ok">✓ ${esc(name(r.player_id))}</span>` : '<span class="no">noch offen</span>'}</div>`).join('')}
    </div>` : '';
    return `<div class="card month">${head}${conf}</div>`;
  }

  /** Rangliste des Monats (Trainer-Schnitt, daneben Mannschaft) mit „Zustimmen". */
  function rankList(ranking, honoredId, crown, me) {
    if (!ranking || !ranking.length) return '<p class="sub">Noch keine Trainer-Noten in diesem Monat.</p>';
    let place = 0, last = null;
    return ranking.map((r, i) => {
      const a = Math.round((r.t?.avg ?? 0) * 100);
      if (a !== last) { place = i + 1; last = a; }
      const p = { id: r.id, name: r.name, number: r.number };
      const on = r.id === honoredId;
      const voters = (crown?.required || []).filter((x) => x.player_id === r.id);
      const mine = (crown?.required || []).some((x) => x.rater_id === me && x.player_id === r.id);
      const initials2 = (n) => String(n || '?').split(/\s+/).map((w) => w[0]).slice(0, 2).join('').toUpperCase();
      return `<div class="rk ${place === 1 ? 'top' : ''} ${on ? 'crowned' : ''}"><div class="pl">${place}</div>${avatar(p, { [r.id]: r.photo })}
        <div class="nm">${esc(r.name)}<small><b>Trainer ${f1(r.t?.avg)}</b> (${r.t?.n ?? 0})${r.m ? ` · <i>Mannschaft ${f1(r.m.avg)}</i> (${r.m.n})` : ''}</small>
        ${voters.length ? `<div class="who2">${voters.map((v) => `<span title="${esc(v.name)}">✓ ${esc(initials2(v.name))}</span>`).join('')}</div>` : ''}</div>
        <button type="button" class="crownbtn ${mine ? 'mine' : ''}" data-crown="${esc(r.id)}" data-name="${esc(r.name)}" data-mine="${mine ? 1 : 0}">${mine ? '✓ Deine Stimme' : 'Zustimmen'}</button></div>`;
    }).join('');
  }

  /** Verlauf der letzten Gekürten. */
  function historyStrip(history) {
    if (!history || !history.length) return '';
    return '<div class="hist">' + history.map((h) =>
      `<div>${avatar({ id: h.id, name: h.name, number: null }, { [h.id]: h.photo })}<b>${esc(h.name || '–')}</b><span>${esc(monthLabel(h.year_month, true))}</span></div>`).join('') + '</div>';
  }

  /** Übersicht aller Spiele (Trainer): Noten, Stand, Spieler des Spiels. */
  function overviewList(games, sel, logos, usName) {
    if (!games || !games.length) return '';
    const rows = games.map((g) => {
      const parts = String(g.title).match(/^(.*?)\s+–\s+(.*?)\s+\d+:\d+$/) || [];
      const opp = parts[1] ? (parts[1] === usName ? parts[2] : parts[1]) : g.title;
      const mo = g.motm ? `<div class="mo">${avatar({ id: g.motm.id, name: g.motm.name }, { [g.motm.id]: g.motm.photo })}👑 ${esc(g.motm.name || '')} <span style="color:var(--muted);font-weight:500">(${g.motm.votes})</span></div>` : '';
      return `<div class="og ${g.match_id === sel ? 'on' : ''}" data-og="${esc(g.match_id)}">${crest(logos?.[g.match_id], opp)}
        <div class="bd"><div class="tt">${esc(g.title)}<small>${esc(fmtDate(g.match_date))}${g.open ? ` · <span class="dot"></span>offen bis ${esc(fmtDate(g.closes_at))}` : ' · beendet'}</small></div>
        <div class="nums"><span class="t">Trainer <b>${g.coach_avg != null ? f1(g.coach_avg) : '–'}</b> (${g.coach_done}/${g.coach_total})</span>
        <span class="m">Mannschaft <b>${g.team_avg != null ? f1(g.team_avg) : '–'}</b> (${g.voters}/${g.players})</span></div>${mo}</div></div>`;
    }).join('');
    return `<details class="all"><summary>Alle Spiele <small>${games.length} Spiele · Trainer &amp; Mannschaft</small></summary>${rows}</details>`;
  }

  /** Stimmen der Trainer (einzeln, aufklappbar). */
  function coachVotesCard(votes, byId, photos, meId) {
    if (!votes || !votes.length) return '';
    const sorted = (ids) => sortPlayers(ids.map((id) => byId[id] || { id, name: 'Unbekannt' }));
    return '<div class="card"><h2>Stimmen der Trainer</h2><p class="sub">Jede Trainer-Stimme einzeln – tippen zeigt die Spielernoten.</p>' + votes.map((v) => {
      const motm = v.motm_player_id ? (byId[v.motm_player_id]?.name || 'Unbekannt') : null;
      const ids = Object.keys(v.stars || {});
      const info = [
        v.abstained ? 'war nicht da' : (v.match_stars != null ? `Spiel ${stars(v.match_stars)}` : 'keine Spielnote'),
        motm ? `👑 ${esc(motm)}` : null,
        v.note ? '📝 Bericht' : null,
        ids.length ? `${ids.length} Spieler` : null,
      ].filter(Boolean).map((x) => `<em style="font-style:normal">${x}</em>`).join('');
      const pv = sorted(ids).map((p) => `<div class="pv">${avatar(p, photos)}<span class="n">${esc(p.name)}</span>${stars(v.stars[p.id])}</div>`).join('');
      return `<details class="cv"><summary>${avatar({ id: v.rater_id, name: v.name }, { [v.rater_id]: v.photo })}
        <div class="who"><b>${esc(v.name)}${v.rater_id === meId ? ' (du)' : ''}</b><span>${info}</span></div></summary>
        ${v.note ? `<div class="rep">${esc(v.note).replace(/\n/g, '<br>')}</div>` : ''}${pv || '<div class="pv" style="color:var(--muted)">Keine Spielernoten.</div>'}</details>`;
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

  /** Klasse des i-ten Sterns für Wert v: voll, halb oder leer. */
  const starClass = (i, v) => (v == null ? '' : v >= i ? 'on' : v >= i - 0.5 ? 'half' : '');
  const half = (v) => Math.max(0, Math.min(5, Math.round((Number(v) || 0) * 2) / 2));

  function starsInput(key, value, cls) {
    let h = `<div class="stars ${cls || ''}" data-key="${esc(key)}" role="radiogroup">`;
    for (let i = 1; i <= 5; i++) h += `<button type="button" data-v="${i}" class="${starClass(i, value)}" aria-label="${i} Sterne (links tippen = ${i - 0.5})">★</button>`;
    return h + '</div>';
  }
  /** Anzeige mit halben Sternen (Schnitte werden auf 0,5 gerundet). */
  function stars(v) {
    const n = half(v);
    const full = Math.floor(n), hs = n - full >= 0.5;
    return `<span class="st">${'★'.repeat(full)}${hs ? '<b class="hs">★</b>' : ''}<i>${'★'.repeat(5 - full - (hs ? 1 : 0))}</i></span>`;
  }
  /** Kurztext, z. B. „★★★½“. */
  function starText(v) {
    const n = half(v);
    return '★'.repeat(Math.floor(n)) + (n % 1 ? '½' : '');
  }

  /** Sterne-Klicks binden; onChange(key, value|null). Nochmal tippen nimmt zurück. */
  function bindStars(root, getValue, onChange) {
    root.querySelectorAll('.stars').forEach((el) => {
      el.addEventListener('click', (e) => {
        const b = e.target.closest('button');
        if (!b) return;
        // Linke Sternhälfte = halber Stern, rechte = ganzer (Tastatur: ganz).
        const i = Number(b.dataset.v);
        const rect = b.getBoundingClientRect();
        let v = e.detail !== 0 && e.clientX - rect.left < rect.width / 2 ? i - 0.5 : i;
        if (getValue(el.dataset.key) === v) v = null;
        onChange(el.dataset.key, v);
        el.querySelectorAll('button').forEach((x) => {
          x.classList.remove('on', 'half');
          const c = starClass(Number(x.dataset.v), v);
          if (c) x.classList.add(c);
        });
        b.classList.add('pop');
        setTimeout(() => b.classList.remove('pop'), 140);
        const row = el.closest('.prow');
        if (row) row.classList.toggle('done', v != null);
      });
    });
  }

  function playerRow(p, photos, key, value, sub) {
    return `<div class="prow ${value ? 'done' : ''}">${avatar(p, photos)}<div class="nm">${esc(p.name)}${sub ? `<small>${esc(sub)}</small>` : ''}<div class="bdgs" data-bdg="${esc(p.id)}"></div></div>${starsInput(key, value, 'sm')}</div>`;
  }

  function motmTiles(players, photos, selected) {
    return '<div class="motm">' + players.map((p) =>
      `<button type="button" class="mt ${selected === p.id ? 'on' : ''}" data-motm="${esc(p.id)}"><span class="mini" data-bdg-mini="${esc(p.id)}"></span>${avatar(p, photos)}<span class="nm">${esc(p.name)}</span></button>`).join('') + '</div>';
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

  return { crownCard, applyBadges, overviewList, coachVotesCard, starText, monthLabel, monthCard, rankList, historyStrip, profile, profileCard, entriesCard, entryStatus, token, rpc, media, esc, fmtDate, f1, crest, avatar, scoreboard, matchTiles, starsInput, stars, bindStars,
    playerRow, motmTiles, podium, gradeTiles, bars, sortPlayers, message, safeImg };
})();
