-- =====================================================================
-- Fungsi ADMIN — hanya dijalankan manual dari SQL Editor (tidak bisa dipanggil anon)
-- =====================================================================

-- Generate N kartu baru: hasilnya uid + kode aktivasi (untuk NFC/QR dan dicetak di kartu)
create or replace function public.admin_generate_cards(p_count int, p_prefix text default 'TR')
returns table(card_uid text, activation_code text)
language plpgsql security definer set search_path = public, extensions as $$
declare i int := 0; v_uid text; v_code text;
begin
  if p_count not between 1 and 5000 then raise exception 'p_count harus 1..5000'; end if;
  if p_prefix !~ '^[A-Za-z0-9]{1,8}$' then raise exception 'prefix tidak valid'; end if;
  while i < p_count loop
    v_uid := upper(p_prefix) || '-' || upper(encode(gen_random_bytes(4), 'hex'));
    v_code := upper(encode(gen_random_bytes(4), 'hex'));
    begin
      insert into public.cards as c(card_uid, activation_code) values (v_uid, v_code);
      i := i + 1; card_uid := v_uid; activation_code := v_code; return next;
    exception when unique_violation then null;  -- uid bentrok: ulangi
    end;
  end loop;
end $$;

-- Reset kartu (pemilik lupa sandi / kartu dijual ulang): nonaktifkan + kode aktivasi baru
create or replace function public.admin_reset_card(p_uid text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_code text := upper(encode(gen_random_bytes(4), 'hex'));
begin
  update public.cards c
     set is_active = false, place_id = null, business_name = null, review_url = null,
         password_hash = null, failed_attempts = 0, locked_until = null,
         activation_code = v_code, updated_at = now()
   where c.card_uid = p_uid;
  if not found then raise exception 'kartu % tidak ada', p_uid; end if;
  return v_code;
end $$;

revoke all on function public.admin_generate_cards(int,text) from public, anon, authenticated;
revoke all on function public.admin_reset_card(text)         from public, anon, authenticated;

-- Contoh pakai:
--   select * from public.admin_generate_cards(100, 'TR');   -- copy hasilnya ke CSV
--   select public.admin_reset_card('TR-88291A');            -- kode aktivasi baru
--   select card_uid, business_name, is_active, activated_at from public.cards order by created_at desc;
