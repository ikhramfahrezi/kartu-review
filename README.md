# Kartu Review Google Maps (NFC + QR) — versi tanpa Google Cloud

Tap/scan kartu → `https://DOMAIN/?uid=TR-XXXXXXXX` → langsung ke form review Google Maps.
Kartu baru → `/activate` (kode aktivasi + Place ID + sandi). Ganti lokasi di `/manage?uid=...`.
**Tidak butuh Google Cloud / API key / kartu kredit.** Place ID dicari manual lewat alat gratis Google.

```
public/     index.html activate.html manage.html 404.html css/ js/app.js _headers
supabase/   schema.sql (tabel + RLS + 3 RPC)   admin.sql (generate & reset kartu)
tests/      smoke-test.sh      .github/keepalive.yml      build.sh
```

## Setup
1. **GitHub**: repo private, push folder ini (`.env` sudah di .gitignore).
2. **Supabase**: project baru (region Singapore) → SQL Editor → jalankan `supabase/schema.sql` lalu `supabase/admin.sql`.
   Settings → API: catat Project URL + anon/publishable key (JANGAN service_role; `build.sh` menolaknya).
3. **Tes keamanan**: `SUPABASE_URL=... SUPABASE_ANON_KEY=... sh tests/smoke-test.sh` → semua PASS.
4. **Lokal**: `cp .env.example .env` (isi 2 nilai) → `sh build.sh && npx wrangler pages dev dist`.
5. **Cloudflare Pages**: connect repo, build command `sh build.sh`, output `dist`, env var `SUPABASE_URL` + `SUPABASE_ANON_KEY`.
6. **Domain**: Custom domains → mis. `r.namadomain.com`. Jangan ganti setelah kartu dicetak (URL tertanam di NFC/QR).
7. **GitHub Secrets** `SUPABASE_URL`, `SUPABASE_ANON_KEY`, lalu jalankan workflow *keepalive* sekali.
8. 2FA di semua akun; jadwalkan backup `pg_dump` mingguan.

## SOP aktivasi di toko
1. Admin generate kartu: `select * from admin_generate_cards(100,'TR');` → simpan CSV (uid + kode aktivasi). Tulis uid ke NFC/QR, cetak kode di belakang kartu.
2. Di toko, buka Google dengan kata kunci **"Place ID Finder"** (alat resmi Google, tanpa login/key), cari nama toko + alamat, salin **Place ID** (biasanya diawali `ChIJ`).
3. Scan kartu → halaman aktivasi → isi kode aktivasi, nama toko, tempel Place ID, buat sandi.
4. Klik **Tes link review**: harus terbuka form review toko yang benar. Kalau salah toko, perbaiki Place ID sebelum menekan *Aktifkan*.
5. Aktifkan, lalu scan ulang kartu dan pastikan langsung ke form review.
6. Kasih sandi ke pemilik toko (catat di tempat aman kalau lu yang pegang).

Tip: kalau toko punya link "Minta ulasan" dari Google Business Profile, itu tetap harus dikonversi ke Place ID; cara paling pasti ya lewat Place ID Finder.

## Ketahanan
Retry + backoff untuk request baca; request tulis tidak di-retry; fallback offline (URL terakhir di-cache di HP); anti double-submit; Back/bfcache ditangani; pesan error jelas + tombol coba lagi; tanpa library eksternal sama sekali, CSP: `script-src 'self'`.

## Keamanan
RLS + FORCE + semua hak anon dicabut; hanya 3 RPC `SECURITY DEFINER`; sandi bcrypt; salah 5x → kartu terkunci 15 menit; kode aktivasi mencegah aktivasi oleh orang lain; redirect hanya ke `search.google.com/local/writereview?placeid=...`; semua teks lewat `textContent`.
Catatan: karena Place ID tidak divalidasi ke Google, nama toko di database hanya catatan; kebenaran lokasi dicek manual lewat tombol *Tes link review*.

## Operasional
- Lupa sandi / kartu dijual ulang: `select admin_reset_card('TR-XXXXXXXX');`
- Pantau: `select card_uid, business_name, activated_at from cards order by created_at desc;`
- Ganti lokasi untuk pelanggan: buka `/manage?uid=...` (butuh sandi), atau reset kartu lalu aktivasi ulang.

## Saran lanjutan
Cloudflare Turnstile di form; counter scan; kode pemulihan sandi; domain pendek; backup rutin.
Kalau nanti punya Google Cloud, versi dengan Autocomplete bisa dipasang lagi tanpa ubah database.
