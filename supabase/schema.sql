-- =====================================================================
-- Kartu Review Google Maps — schema Supabase (idempotent, aman dijalankan ulang)
-- Jalankan di: Supabase Dashboard > SQL Editor
-- =====================================================================
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.cards (
  card_uid        text primary key check (card_uid ~ '^[A-Za-z0-9-]{4,32}$'),
  is_active       boolean not null default false,
  place_id        text check (place_id ~ '^[A-Za-z0-9_-]{10,300}$'),
  business_name   text check (char_length(business_name) between 1 and 200),
  review_url      text,
  password_hash   text,
  failed_attempts int  not null default 0,
  locked_until    timestamptz,
  created_at      timestamptz not null default now(),
  activated_at    timestamptz,
  updated_at      timestamptz not null default now(),
  constraint active_requires_data check (
    not is_active or (place_id is not null and password_hash is not null and review_url is not null))
);

-- Kode aktivasi (dicetak di belakang kartu) => mencegah orang lain mengaktifkan kartu duluan
alter table public.cards
  add column if not exists activation_code text not null
  default upper(encode(extensions.gen_random_bytes(4), 'hex'));

-- ---- RLS: kunci total. Tanpa policy => anon/authenticated tidak bisa akses langsung ----
alter table public.cards enable row level security;
alter table public.cards force  row level security;
revoke all on table public.cards from anon, authenticated, public;

-- ---- 1) check_card_status: tidak pernah mengembalikan hash/kode ----
create or replace function public.check_card_status(p_uid text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r public.cards;
begin
  if p_uid is null or p_uid !~ '^[A-Za-z0-9-]{4,32}$' then
    return jsonb_build_object('found', false);
  end if;
  select * into r from public.cards where card_uid = p_uid;
  if not found then return jsonb_build_object('found', false); end if;
  return jsonb_build_object('found', true, 'is_active', r.is_active,
                            'review_url', case when r.is_active then r.review_url end);
end $$;

-- ---- 2) activate_card: atomik (row lock) + cek kode aktivasi + rate limit ----
drop function if exists public.activate_card(text,text,text,text);
create or replace function public.activate_card(
  p_uid text, p_place_id text, p_business_name text, p_password text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r public.cards; v_url text; v_code text := upper(trim(coalesce(p_code, '')));
begin
  if p_uid is null or p_uid !~ '^[A-Za-z0-9-]{4,32}$'
     or p_place_id is null or p_place_id !~ '^[A-Za-z0-9_-]{10,300}$'
     or p_business_name is null or char_length(trim(p_business_name)) not between 1 and 200
     or p_password is null or char_length(p_password) not between 6 and 72
     or v_code !~ '^[A-Z0-9]{4,16}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_input');
  end if;

  select * into r from public.cards where card_uid = p_uid and not is_active for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_available'); end if;

  if r.locked_until is not null and r.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked');
  end if;

  if r.activation_code <> v_code then
    update public.cards
       set failed_attempts = failed_attempts + 1,
           locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' end,
           updated_at = now()
     where card_uid = p_uid;
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;

  v_url := 'https://search.google.com/local/writereview?placeid=' || p_place_id;
  update public.cards
     set is_active = true, place_id = p_place_id, business_name = trim(p_business_name),
         review_url = v_url, password_hash = crypt(p_password, gen_salt('bf', 10)),
         failed_attempts = 0, locked_until = null, activated_at = now(), updated_at = now()
   where card_uid = p_uid;
  return jsonb_build_object('ok', true, 'review_url', v_url);
end $$;

-- ---- 3) update_card_location: verifikasi sandi + rate limit (5x salah => kunci 15 menit) ----
-- RETURN (bukan RAISE) supaya counter gagal tetap ter-commit.
create or replace function public.update_card_location(
  p_uid text, p_password text, p_new_place_id text, p_new_business_name text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r public.cards; v_url text;
begin
  if p_uid is null or p_uid !~ '^[A-Za-z0-9-]{4,32}$'
     or p_new_place_id is null or p_new_place_id !~ '^[A-Za-z0-9_-]{10,300}$'
     or p_new_business_name is null or char_length(trim(p_new_business_name)) not between 1 and 200
     or p_password is null or char_length(p_password) not between 1 and 72 then
    return jsonb_build_object('ok', false, 'error', 'invalid_input');
  end if;

  select * into r from public.cards where card_uid = p_uid and is_active for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'invalid_credentials'); end if;

  if r.locked_until is not null and r.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked');
  end if;

  if r.password_hash is distinct from crypt(p_password, r.password_hash) then
    update public.cards
       set failed_attempts = failed_attempts + 1,
           locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' end,
           updated_at = now()
     where card_uid = p_uid;
    return jsonb_build_object('ok', false, 'error', 'invalid_credentials');
  end if;

  v_url := 'https://search.google.com/local/writereview?placeid=' || p_new_place_id;
  update public.cards
     set place_id = p_new_place_id, business_name = trim(p_new_business_name),
         review_url = v_url, failed_attempts = 0, locked_until = null, updated_at = now()
   where card_uid = p_uid;
  return jsonb_build_object('ok', true, 'review_url', v_url);
end $$;

-- ---- Hak eksekusi: HANYA 3 RPC ini untuk anon ----
revoke all on function public.check_card_status(text) from public, anon, authenticated;
revoke all on function public.activate_card(text,text,text,text,text) from public, anon, authenticated;
revoke all on function public.update_card_location(text,text,text,text) from public, anon, authenticated;
grant execute on function public.check_card_status(text) to anon, authenticated;
grant execute on function public.activate_card(text,text,text,text,text) to anon, authenticated;
grant execute on function public.update_card_location(text,text,text,text) to anon, authenticated;
