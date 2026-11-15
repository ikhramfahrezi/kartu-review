#!/bin/sh
# Smoke test keamanan: SUPABASE_URL=... SUPABASE_ANON_KEY=... sh tests/smoke-test.sh
set -u
: "${SUPABASE_URL:?}" "${SUPABASE_ANON_KEY:?}"
H1="apikey: $SUPABASE_ANON_KEY"; H2="Content-Type: application/json"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $1"; }; bad(){ fail=$((fail+1)); echo "FAIL  $1"; }
rpc(){ curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$1" -H "$H1" -H "$H2" -d "$2"; }

out=$(curl -s "$SUPABASE_URL/rest/v1/cards?select=*" -H "$H1")
case "$out" in *password_hash*|*activation_code\":*) bad "tabel bocor!";; *) ok "SELECT langsung tidak membocorkan data";; esac
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$SUPABASE_URL/rest/v1/cards?card_uid=neq.x" -H "$H1")
case "$code" in 401|403|404) ok "DELETE langsung ditolak ($code)";; *) bad "DELETE langsung -> $code";; esac
rpc check_card_status '{"p_uid":"ZZ-NOPE-0000"}' | grep -q '"found": *false' && ok "uid tidak ada => found:false" || bad "uid tidak ada"
rpc check_card_status "{\"p_uid\":\"x' OR '1'='1\"}" | grep -q '"found": *false' && ok "payload injeksi ditolak" || bad "payload injeksi"
rpc update_card_location '{"p_uid":"ZZ-NOPE-0000","p_password":"x","p_new_place_id":"ChIJ0000000000","p_new_business_name":"t"}' \
  | grep -q 'invalid_credentials' && ok "update kredensial salah ditolak" || bad "update kredensial salah"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$SUPABASE_URL/rest/v1/rpc/admin_generate_cards" -H "$H1" -H "$H2" -d '{"p_count":1}')
case "$code" in 401|403|404) ok "admin_generate_cards tertutup ($code)";; *) bad "admin_generate_cards terbuka! ($code)";; esac
echo "---- $pass lulus, $fail gagal"; [ "$fail" -eq 0 ]
