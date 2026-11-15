/* Logic bersama index / activate / manage.
 * Prinsip tahan banting: validasi ketat, retry untuk request baca, tanpa retry untuk request tulis,
 * anti double-submit, fallback cache saat offline, textContent only (anti XSS), redirect hanya ke Google Review. */
(() => {
  'use strict';
  const C = window.APP_CONFIG || {};
  const UID_RE = /^[A-Za-z0-9-]{4,32}$/;
  const REVIEW_RE = /^https:\/\/search\.google\.com\/local\/writereview\?placeid=[A-Za-z0-9_-]{10,300}$/;
  const ERR = {
    invalid_input: 'Data tidak valid. Periksa kembali isian Anda.',
    not_available: 'Kartu tidak tersedia atau sudah aktif.',
    invalid_code: 'Kode aktivasi salah.',
    invalid_credentials: 'Sandi salah.',
    locked: 'Terlalu banyak percobaan. Coba lagi dalam 15 menit.',
  };
  const NET_MUTATE = 'Koneksi bermasalah. Jika ragu, buka ulang link kartu untuk mengecek status.';

  const $ = (id) => document.getElementById(id);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const show = (id, on = true) => { const e = $(id); if (e) e.hidden = !on; };
  const store = {  // localStorage bisa diblokir (mode privat) => selalu try/catch
    get: (k) => { try { return localStorage.getItem('kr:' + k); } catch { return null; } },
    set: (k, v) => { try { localStorage.setItem('kr:' + k, v); } catch { /* abaikan */ } },
    del: (k) => { try { localStorage.removeItem('kr:' + k); } catch { /* abaikan */ } },
  };

  function msg(text, type = 'error') {
    const e = $('msg'); if (!e) return;
    e.textContent = text; e.className = 'msg ' + type; e.hidden = false;
  }
  const clearMsg = () => show('msg', false);
  function fatal(text, retry = false) {
    show('loader', false); show('form', false); msg(text); show('retry', retry);
  }
  const getUid = () => {
    const u = new URLSearchParams(location.search).get('uid');
    return u && UID_RE.test(u) ? u : null;
  };

  let redirecting = false;
  function goReview(url) {
    if (redirecting) return;
    if (typeof url === 'string' && REVIEW_RE.test(url)) { redirecting = true; location.replace(url); }
    else fatal('URL review tidak valid. Hubungi admin.');
  }

  // RPC Supabase. retries hanya untuk request BACA (idempotent); tulis = retries 0.
  async function rpc(fn, args, { retries = 2, timeout = 8000 } = {}) {
    const headers = { 'Content-Type': 'application/json', apikey: C.SUPABASE_ANON_KEY };
    if (String(C.SUPABASE_ANON_KEY).startsWith('eyJ')) headers.Authorization = 'Bearer ' + C.SUPABASE_ANON_KEY;
    let lastErr;
    for (let i = 0; i <= retries; i++) {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), timeout);
      try {
        const r = await fetch(`${C.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
          method: 'POST', headers, body: JSON.stringify(args), signal: ctrl.signal, cache: 'no-store' });
        if (r.status >= 500 || r.status === 429) throw Object.assign(new Error('server'), { retryable: true });
        if (!r.ok) throw Object.assign(new Error('HTTP ' + r.status), { retryable: false });
        const data = await r.json();
        if (!data || typeof data !== 'object') throw Object.assign(new Error('bad-response'), { retryable: false });
        return data;
      } catch (e) {
        lastErr = e;
        const retryable = e.name === 'AbortError' || e instanceof TypeError || e.retryable;
        if (!retryable || i === retries) break;
        await sleep(400 * 2 ** i + Math.random() * 200);
      } finally { clearTimeout(t); }
    }
    throw lastErr;
  }

  // ---- Place ID (diinput manual oleh admin/pemilik; tanpa Google Maps API) ----
  const REVIEW_PREFIX = 'https://search.google.com/local/writereview?placeid=';
  const PID_RE = /^[A-Za-z0-9_-]{20,300}$/;
  function parsePlaceId(raw) {
    let v = String(raw || '').trim();
    const m = v.match(/[?&]placeid=([A-Za-z0-9_-]+)/i);   // boleh tempel URL review lengkap
    if (m) v = m[1];
    return PID_RE.test(v) ? v : null;
  }
  function bindTestLink() {
    const b = $('testlink'); if (!b) return;
    b.addEventListener('click', () => {
      clearMsg();
      const pid = parsePlaceId($('pid').value);
      if (!pid) return msg('Place ID tidak valid. Salin ulang dari Place ID Finder (biasanya diawali ChIJ).');
      window.open(REVIEW_PREFIX + pid, '_blank', 'noopener');
    });
  }

  // Anti double-submit + kunci form selama proses. task() return true => biarkan terkunci (sukses/redirect).
  function guard(form, label, validate, task) {
    const btn = $('submit'), fs = $('fs'); let busy = false;
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      if (busy) return;
      clearMsg();
      const problem = validate(); if (problem) return msg(problem);
      busy = true; btn.disabled = true; btn.textContent = 'Memproses…'; fs.disabled = true;
      let keep = false;
      try { keep = (await task()) === true; } catch { msg(NET_MUTATE); }
      if (!keep) { busy = false; btn.disabled = false; btn.textContent = label; fs.disabled = false; }
    });
  }
  function bindPwToggle() {
    const t = $('showpw'); if (!t) return;
    t.addEventListener('change', () => ['pw', 'pw2'].forEach((id) => { const e = $(id); if (e) e.type = t.checked ? 'text' : 'password'; }));
  }

  // ---------------- index ----------------
  async function pageIndex(uid) {
    try {
      const s = await rpc('check_card_status', { p_uid: uid });
      if (!s.found) { store.del(uid); return fatal('Kartu tidak terdaftar.'); }
      if (!s.is_active) { store.del(uid); return location.replace('/activate?uid=' + encodeURIComponent(uid)); }
      store.set(uid, s.review_url);
      goReview(s.review_url);
    } catch {
      const cached = store.get(uid);               // fallback offline: pakai URL terakhir yang valid
      if (cached && REVIEW_RE.test(cached)) return goReview(cached);
      fatal('Koneksi bermasalah. Coba lagi.', true);
    }
  }

  // ---------------- activate ----------------
  async function pageActivate(uid) {
    let s;
    try { s = await rpc('check_card_status', { p_uid: uid }); } catch { return fatal('Koneksi bermasalah. Coba lagi.', true); }
    if (!s.found) return fatal('Kartu tidak terdaftar.');
    if (s.is_active) return goReview(s.review_url);
    show('loader', false); show('form', true); bindPwToggle(); bindTestLink();
    const code = $('code');
    code.addEventListener('input', () => { code.value = code.value.toUpperCase().replace(/[^A-Z0-9]/g, ''); });

    guard($('form'), 'Aktifkan Kartu', () => {
      if (code.value.length < 4) return 'Masukkan kode aktivasi dari belakang kartu.';
      if (!$('bname').value.trim()) return 'Isi nama toko.';
      if (!parsePlaceId($('pid').value)) return 'Place ID tidak valid. Salin ulang dari Place ID Finder.';
      const pw = $('pw').value;
      if (pw.length < 6 || pw.length > 72) return 'Sandi harus 6–72 karakter.';
      if (pw !== $('pw2').value) return 'Konfirmasi sandi tidak cocok.';
      return null;
    }, async () => {
      const r = await rpc('activate_card', { p_uid: uid, p_place_id: parsePlaceId($('pid').value),
        p_business_name: $('bname').value.trim().slice(0, 200), p_password: $('pw').value, p_code: code.value },
        { retries: 0, timeout: 12000 });
      if (r.ok && REVIEW_RE.test(r.review_url)) {
        store.set(uid, r.review_url);
        msg('Kartu aktif! Mengalihkan ke Google Review…', 'ok');
        setTimeout(() => goReview(r.review_url), 1500);
        return true;
      }
      msg(ERR[r.error] || 'Aktivasi gagal. Coba lagi.');
      return false;
    });
  }

  // ---------------- manage ----------------
  async function pageManage(uid) {
    let s;
    try { s = await rpc('check_card_status', { p_uid: uid }); } catch { return fatal('Koneksi bermasalah. Coba lagi.', true); }
    if (!s.found) return fatal('Kartu tidak terdaftar.');
    if (!s.is_active) return location.replace('/activate?uid=' + encodeURIComponent(uid));
    show('loader', false); show('form', true); bindPwToggle(); bindTestLink();

    guard($('form'), 'Simpan Lokasi', () => {
      if (!$('pw').value) return 'Masukkan sandi pengaman.';
      if (!$('bname').value.trim()) return 'Isi nama toko.';
      if (!parsePlaceId($('pid').value)) return 'Place ID tidak valid. Salin ulang dari Place ID Finder.';
      return null;
    }, async () => {
      const name = $('bname').value.trim().slice(0, 200);
      const r = await rpc('update_card_location', { p_uid: uid, p_password: $('pw').value,
        p_new_place_id: parsePlaceId($('pid').value), p_new_business_name: name }, { retries: 0, timeout: 12000 });
      if (r.ok && REVIEW_RE.test(r.review_url)) {
        store.set(uid, r.review_url);
        $('pw').value = '';
        msg('Lokasi berhasil diperbarui. Kartu sekarang mengarah ke "' + name + '".', 'ok');
      } else msg(ERR[r.error] || 'Gagal menyimpan. Coba lagi.');
      return false;
    });
  }

  // ---------------- boot ----------------
  const page = document.body.dataset.page;
  window.addEventListener('pageshow', (e) => { if (e.persisted && page !== 'notfound') location.reload(); }); // Back / bfcache
  if ($('retry')) $('retry').addEventListener('click', () => location.reload());
  if (page === 'notfound') return;
  if (!C.SUPABASE_URL || !C.SUPABASE_ANON_KEY) {
    return fatal('Konfigurasi aplikasi belum lengkap (config.js).');
  }
  const uid = getUid();
  if (!uid) return fatal('Link kartu tidak valid.');
  ({ index: pageIndex, activate: pageActivate, manage: pageManage }[page] || (() => {}))(uid);
})();
