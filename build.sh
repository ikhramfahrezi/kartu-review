#!/bin/sh
# Cloudflare Pages -> Build command: sh build.sh   Output dir: dist
# Lokal: isi .env (lihat .env.example) lalu: sh build.sh && npx wrangler pages dev dist
set -eu
if [ -f .env ]; then set -a; . ./.env; set +a; fi
: "${SUPABASE_URL:?SUPABASE_URL belum diisi}" "${SUPABASE_ANON_KEY:?SUPABASE_ANON_KEY belum diisi}"
case "$SUPABASE_URL$SUPABASE_ANON_KEY" in *\"*|*\\*|*\ *) echo "Env mengandung karakter terlarang"; exit 1;; esac
case "$SUPABASE_ANON_KEY" in *service_role*|sb_secret_*) echo "JANGAN pakai service_role/secret key di frontend!"; exit 1;; esac
rm -rf dist && mkdir -p dist && cp -R public/. dist/
printf 'window.APP_CONFIG={SUPABASE_URL:"%s",SUPABASE_ANON_KEY:"%s"};\n' "$SUPABASE_URL" "$SUPABASE_ANON_KEY" > dist/config.js
echo "Build OK -> dist/"
