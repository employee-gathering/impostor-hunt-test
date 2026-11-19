-- CIH / Impostor Hunt
-- Migration: Simplified Participant Flow
-- Extracted from the supplied combined SQL file.
--
-- IMPORTANT:
-- 1. This migration assumes the foundational CIH schema already exists.
-- 2. Review dependencies, grants, policies, and legacy role usage before execution.
-- 3. This file intentionally does not include the private participant roster/NID data.
-- 4. Do not execute against production until a database backup and staging test are complete.
--
-- CIH Simplified Participant Flow
-- Apply after a database backup. This migration changes the Impostor Hunt
-- participant flow to TIM + NID login, shared player QR, no ride staff verification,
-- direct team voucher issue after final submission, and Admin-only operations.
-- Participant roster personal data is intentionally kept in a separate private import SQL.

begin;

-- Admin is the only staff permission. Keep existing admin_users as the source of truth.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and exists (select 1 from public.admin_users where user_id = auth.uid());
$$;

create or replace function public.ih_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin();
$$;
revoke all on function public.ih_is_admin() from public;

grant execute on function public.ih_is_admin() to authenticated;

-- Retire all application-specific role assignments and role-management RPCs.
do $$
begin
  if to_regclass('public.app_user_roles') is not null then
    execute 'delete from public.app_user_roles';
  end if;
end $$;

drop function if exists public.ih_admin_list_role_assignments();
drop function if exists public.ih_admin_grant_role(text,text);
drop function if exists public.ih_admin_revoke_role(text,text);
-- Existing RLS policies may call this helper. Keep the function to avoid breaking
-- policy dependencies, but collapse every legacy role check to the Admin allow-list.
create or replace function public.ih_has_any_role(p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin();
$$;
revoke all on function public.ih_has_any_role(text[]) from public;
grant execute on function public.ih_has_any_role(text[]) to authenticated;
drop function if exists public.ih_staff_verify_ride(text);

-- Shared participant QR master set. Only token hashes are stored.
create table if not exists public.ih_shared_player_qr_codes (
  player_number smallint primary key check (player_number between 1 and 18),
  color_code text not null references public.ih_colors(code),
  destination_code text not null,
  destination_name text not null,
  destination_type text not null,
  token_hash text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.ih_shared_player_qr_codes enable row level security;
revoke all on public.ih_shared_player_qr_codes from anon, authenticated;

insert into public.ih_shared_player_qr_codes
  (player_number,color_code,destination_code,destination_name,destination_type,token_hash)
values
  (1,'RED','LOC-07','Pacific Rim','REGULAR','37f31586a10663260fa309fc3a474047e2e80b99cd56b0e5f0d702f3268a8d87'),
  (2,'RED','LOC-10','Rock in Tug','REGULAR','9b4043a2b1da2676afe8895c57c50b41785d691c8353fda134572512d895bcb8'),
  (3,'RED','LOC-16','Jurassic Island','EXTREME','6896eb36e6c09fec0c4801b648ac57f9bce68b0c8f011d33cb1541ae65ecdc68'),
  (4,'BLUE','LOC-15','Bat Glider','REGULAR','63f85f3de67d74ebd726e185d5ee933e92ea908002b379ae81d1626dc0301b2c'),
  (5,'BLUE','LOC-09','Gravitron','EXTREME','598316efe722494c3ce42d56bda5a74ec8fc2d8209ec5d2ed567ea5dd8db35c0'),
  (6,'BLUE','LOC-11','Carousel','REGULAR','ce1454ac488436c1060ed244ce45ed8c293cb652258aa342c6bdb1bd6416551e'),
  (7,'GREEN','LOC-06','Boomerang Coaster','EXTREME','456f189ac870974dd30bfd9ae3335d7f73d8a8db694b95dd7d68cfd0de9fb0ac'),
  (8,'GREEN','LOC-17','Monster Wars','EXTREME','6ad2be25a82f604035d2024b12dbaf6da4d81416917969cdc61812a46f40398f'),
  (9,'GREEN','LOC-05','Wave Racer','REGULAR','8a170d774d122586884024af54cf123a6b9b68c04bdd4e292c0be4fc29a11296'),
  (10,'YELLOW','LOC-08','Magic Bike','REGULAR','923e119adc08d1b6eb8d7097e6b41b4a1dddc6ffb7d44050341f556b5b63b86a'),
  (11,'YELLOW','LOC-02','Magical Ball','REGULAR','1f93ad419a37fef0253899597636b4966b7f91cf5ebfc930cda4f0f83bf84db9'),
  (12,'YELLOW','LOC-12','Oriental Express','REGULAR','1f6c0a610b4ec3f45b03b479b868620268b844dfa5265e699348370dcd916df3'),
  (13,'PURPLE','LOC-04','Formula Kart','REGULAR','a184e2d334609b0d709a9ab2dcafe5917788547fa9a50add77a14f3a0259b289'),
  (14,'PURPLE','LOC-03','Snow Playground','REGULAR','31d03955654ebe8fa52a0265eaf8b6eab70e75a3f51547161397a81999bb6ad2'),
  (15,'PURPLE','LOC-13','Tilting Village','REGULAR','5a64bd441b83f508e610e2b8173b30c754249a42a2529cc6f8b349fd927fc3f1'),
  (16,'ORANGE','LOC-01','Science Center','REGULAR','21e291541aa522afc67eaab89690cf9c57175ea851c8ae6efa1f0b2f0be52d2d'),
  (17,'ORANGE','LOC-18','Kingkong Tower','REGULAR','15179098d470b0ed9499a67cea52cd5c5257f528c0a11450b473b6fe1a65fd78'),
  (18,'ORANGE','LOC-14','Alien Taxi','EXTREME','a12fb3f9384de90013fc83d2286a2dd399df198a854024366447707697fb3b1c')
on conflict (player_number) do update set
  color_code=excluded.color_code,
  destination_code=excluded.destination_code,
  destination_name=excluded.destination_name,
  destination_type=excluded.destination_type,
  token_hash=excluded.token_hash,
  active=true;

-- Old per-batch player QR tokens are retired. Existing ride QR tokens are preserved.
update public.ih_qr_codes
set active=false
where qr_type='player' and active=true;

-- Keep the team-to-player pairing used by the original UAT flow. Each team
-- receives one of the three players for each color; team numbers 1-3 repeat
-- the three player slots across the 18 teams. Existing non-null pairings are kept.
alter table public.ih_team_progress
  add column if not exists assigned_player_id uuid
    references public.ih_players(id) on delete restrict;

update public.ih_team_progress p
set assigned_player_id=pl.id
from public.ih_teams t, public.ih_colors c, public.ih_players pl
where p.team_id=t.id
  and p.color_code=c.code
  and pl.session_id=t.session_id
  and pl.player_number=((c.sort_order-1)*3)+((t.team_number-1)%3)+1
  and pl.active=true
  and p.assigned_player_id is null;

do $$
begin
  if exists (
    select 1 from public.ih_team_progress p
    join public.ih_teams t on t.id=p.team_id
    where p.assigned_player_id is null
  ) then
    raise exception 'Ada progres tim yang belum memiliki QR pemain. Periksa penugasan 18 pemain sebelum migrasi dilanjutkan.';
  end if;
end $$;

-- Keep historical staff_verified logs readable, and include the player-slot mismatch result.
alter table public.ih_scan_logs
  drop constraint if exists ih_scan_logs_scan_result_check;
alter table public.ih_scan_logs
  add constraint ih_scan_logs_scan_result_check
  check (scan_result = any (array[
    'player_ok','ride_ok','decoy','wrong_ride','already_completed',
    'invalid','wrong_player','staff_verified'
  ]::text[]));

-- TIM is the participant username (one row per participant), NID is the password.
-- Passwords are stored as bcrypt hashes, never as plain text.
create table if not exists public.ih_participant_accounts (
  id uuid primary key default gen_random_uuid(),
  username text not null unique,
  attendee_id uuid not null unique references public.attendees(id) on delete cascade,
  team_id uuid not null references public.ih_teams(id) on delete cascade,
  password_hash text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ih_participant_accounts_team_idx
  on public.ih_participant_accounts(team_id);
alter table public.ih_participant_accounts enable row level security;
revoke all on public.ih_participant_accounts from anon, authenticated;

-- Basic server-side throttling for the public participant login RPC.
create table if not exists public.ih_participant_login_throttle (
  username text primary key,
  failed_attempts integer not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.ih_participant_login_throttle enable row level security;
revoke all on public.ih_participant_login_throttle from anon, authenticated;

create or replace function public.ih_admin_list_team_members(p_team_id uuid)
returns table(username text, full_name text, nid text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Akses hanya untuk Admin.';
  end if;
  return query
    select pa.username, a.full_name, a.nid
    from public.ih_participant_accounts pa
    join public.attendees a on a.id=pa.attendee_id
    where pa.team_id=p_team_id and pa.active=true and a.active=true
    order by pa.username;
end;
$$;
revoke all on function public.ih_admin_list_team_members(uuid) from public;
grant execute on function public.ih_admin_list_team_members(uuid) to authenticated;

-- Short-lived opaque participant sessions so the browser no longer sends a guessable team code.
create table if not exists public.ih_participant_sessions (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique,
  account_id uuid not null references public.ih_participant_accounts(id) on delete cascade,
  team_id uuid not null references public.ih_teams(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists ih_participant_sessions_expiry_idx
  on public.ih_participant_sessions(expires_at);
alter table public.ih_participant_sessions enable row level security;
revoke all on public.ih_participant_sessions from anon, authenticated;

create or replace function public.ih_participant_login(p_username text,p_password text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_account public.ih_participant_accounts%rowtype;
  v_attendee public.attendees%rowtype;
  v_team public.ih_teams%rowtype;
  v_session public.ih_game_sessions%rowtype;
  v_token text;
  v_username text := upper(trim(coalesce(p_username,'')));
  v_failed integer;
  v_locked_until timestamptz;
begin
  select failed_attempts,locked_until into v_failed,v_locked_until
  from public.ih_participant_login_throttle
  where username=v_username;
  if v_locked_until is not null and v_locked_until>now() then
    return jsonb_build_object('ok',false,'code','login_locked',
      'message','Terlalu banyak percobaan. Coba lagi setelah 15 menit.');
  end if;

  select * into v_account
  from public.ih_participant_accounts
  where username=v_username and active=true;

  if not found or coalesce(trim(p_password),'')='' then
    insert into public.ih_participant_login_throttle(username,failed_attempts,locked_until,updated_at)
    values(v_username,1,null,now())
    on conflict(username) do update set
      failed_attempts=case when public.ih_participant_login_throttle.locked_until is not null
        and public.ih_participant_login_throttle.locked_until<=now() then 1
        else public.ih_participant_login_throttle.failed_attempts+1 end,
      locked_until=case when (
        case when public.ih_participant_login_throttle.locked_until is not null
          and public.ih_participant_login_throttle.locked_until<=now() then 1
          else public.ih_participant_login_throttle.failed_attempts+1 end
      )>=5 then now()+interval '15 minutes' else null end,
      updated_at=now();
    return jsonb_build_object('ok',false,'message','Username TIM atau NID tidak sesuai.');
  end if;

  if extensions.crypt(upper(trim(p_password)),v_account.password_hash) <> v_account.password_hash then
    insert into public.ih_participant_login_throttle(username,failed_attempts,locked_until,updated_at)
    values(v_username,1,null,now())
    on conflict(username) do update set
      failed_attempts=case when public.ih_participant_login_throttle.locked_until is not null
        and public.ih_participant_login_throttle.locked_until<=now() then 1
        else public.ih_participant_login_throttle.failed_attempts+1 end,
      locked_until=case when (
        case when public.ih_participant_login_throttle.locked_until is not null
          and public.ih_participant_login_throttle.locked_until<=now() then 1
          else public.ih_participant_login_throttle.failed_attempts+1 end
      )>=5 then now()+interval '15 minutes' else null end,
      updated_at=now();
    return jsonb_build_object('ok',false,'message','Username TIM atau NID tidak sesuai.');
  end if;

  delete from public.ih_participant_login_throttle where username=v_username;

  select * into v_attendee from public.attendees where id=v_account.attendee_id and active=true;
  select * into v_team from public.ih_teams where id=v_account.team_id;
  select * into v_session from public.ih_game_sessions where id=v_team.session_id;

  if not found or v_attendee.id is null then
    return jsonb_build_object('ok',false,'message','Akun peserta tidak aktif atau tidak ditemukan.');
  end if;

  delete from public.ih_participant_sessions where expires_at < now();
  v_token := encode(extensions.gen_random_bytes(32),'hex');
  insert into public.ih_participant_sessions(token_hash,account_id,team_id,expires_at)
  values (
    encode(extensions.digest(v_token,'sha256'),'hex'),
    v_account.id,v_team.id,now()+interval '12 hours'
  );

  return jsonb_build_object(
    'ok',true,
    'login_token',v_token,
    'username',v_account.username,
    'participant_name',v_attendee.full_name,
    'team_code',v_team.team_code,
    'team_name',v_team.team_name,
    'batch_code',v_session.batch_code,
    'session_status',v_session.status
  );
end;
$$;

create or replace function public.ih_participant_context(p_login_token text)
returns table(
  account_id uuid,
  attendee_id uuid,
  team_id uuid,
  team_code text,
  team_name text,
  batch_code text,
  session_id uuid,
  session_status text,
  participant_name text,
  username text
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select a.id, a.attendee_id, a.team_id, t.team_code, t.team_name,
         s.batch_code, s.id, s.status, p.full_name, a.username
  from public.ih_participant_sessions ps
  join public.ih_participant_accounts a on a.id=ps.account_id and a.active=true
  join public.attendees p on p.id=a.attendee_id and p.active=true
  join public.ih_teams t on t.id=ps.team_id
  join public.ih_game_sessions s on s.id=t.session_id
  where ps.token_hash=encode(extensions.digest(coalesce(p_login_token,''),'sha256'),'hex')
    and ps.expires_at>now();
$$;
revoke all on function public.ih_participant_context(text) from public,anon,authenticated;

-- Public RPCs now require a valid participant session token, not a team code.
drop function if exists public.ih_get_team_state(text);
create function public.ih_get_team_state(p_login_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ctx record;
begin
  select * into v_ctx from public.ih_participant_context(p_login_token);
  if not found then
    return jsonb_build_object('ok',false,'message','Sesi login berakhir. Silakan login kembali.');
  end if;
  return jsonb_build_object(
    'ok',true,
    'team_code',v_ctx.team_code,
    'team_name',v_ctx.team_name,
    'batch_code',v_ctx.batch_code,
    'session_status',v_ctx.session_status,
    'participant_name',v_ctx.participant_name,
    'username',v_ctx.username,
    'has_submitted',exists(select 1 from public.ih_submissions s where s.team_id=v_ctx.team_id),
    'progress',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'color_code',p.color_code,'status',p.status,'letter',p.letter_received
      ) order by c.sort_order),'[]'::jsonb)
      from public.ih_team_progress p
      join public.ih_colors c on c.code=p.color_code
      where p.team_id=v_ctx.team_id
    )
  );
end;
$$;

drop function if exists public.ih_scan_qr(text,text);
create function public.ih_scan_qr(p_login_token text,p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ctx record;
  v_player_qr public.ih_shared_player_qr_codes%rowtype;
  v_ride_qr public.ih_qr_codes%rowtype;
  v_progress public.ih_team_progress%rowtype;
  v_player public.ih_players%rowtype;
  v_ride_name text;
  v_letter text;
  v_delay integer;
  v_started timestamptz;
  v_hash text;
begin
  select * into v_ctx from public.ih_participant_context(p_login_token);
  if not found then
    return jsonb_build_object('ok',false,'code','login_required','message','Sesi login berakhir. Silakan login kembali.');
  end if;
  if v_ctx.session_status <> 'running' then
    return jsonb_build_object('ok',false,'code','not_running','message','Permainan belum dimulai.');
  end if;
  if coalesce(length(p_token),0)=0 or length(p_token)>200 then
    return jsonb_build_object('ok',false,'code','invalid_token','message','QR tidak valid.');
  end if;

  perform 1 from public.ih_teams where id=v_ctx.team_id for update;
  select player_search_delay_seconds,game_started_at
    into v_delay,v_started
  from public.ih_game_settings where session_id=v_ctx.session_id;

  if v_started is null or now()<v_started+make_interval(secs=>coalesce(v_delay,0)) then
    return jsonb_build_object('ok',false,'code','start_delay','message','Tunggu aba-aba admin sebelum mulai scan.');
  end if;

  v_hash := encode(extensions.digest(p_token,'sha256'),'hex');

  select * into v_player_qr
  from public.ih_shared_player_qr_codes
  where token_hash=v_hash and active=true;

  if found then
    select * into v_player
    from public.ih_players
    where session_id=v_ctx.session_id
      and player_number=v_player_qr.player_number
      and color_code=v_player_qr.color_code
      and active=true;

    if not found then
      return jsonb_build_object('ok',false,'code','player_not_configured','message','QR pemain belum dikonfigurasi untuk batch ini.');
    end if;

    select * into v_progress
    from public.ih_team_progress
    where team_id=v_ctx.team_id and color_code=v_player_qr.color_code
    for update;

    if not found then
      return jsonb_build_object('ok',false,'code','no_mission','message','Misi warna ini tidak ditemukan.');
    end if;
    if v_progress.assigned_player_id is distinct from v_player.id then
      insert into public.ih_scan_logs(session_id,team_id,qr_code_id,scan_result,detail)
      values(v_ctx.session_id,v_ctx.team_id,null,'wrong_player',
        jsonb_build_object('player_number',v_player_qr.player_number,'color',v_player_qr.color_code));
      return jsonb_build_object('ok',false,'code','wrong_player','message','Ini bukan pemain yang ditugaskan untuk tim kamu. Cari nomor pemain yang sesuai.');
    end if;
    if v_progress.status='letter_found' then
      return jsonb_build_object('ok',false,'code','already_completed','message','Huruf warna ini sudah terkumpul.');
    end if;
    if exists (
      select 1 from public.ih_team_progress
      where team_id=v_ctx.team_id and status='player_found' and color_code<>v_player_qr.color_code
    ) then
      return jsonb_build_object('ok',false,'code','finish_current','message','Selesaikan scan QR wahana untuk misi sebelumnya terlebih dahulu.');
    end if;

    update public.ih_team_progress
    set status='player_found',player_scanned_at=coalesce(player_scanned_at,now()),updated_at=now()
    where id=v_progress.id;
    select ride_name into v_ride_name
    from public.ih_rides where id=v_progress.assigned_ride_id;

    insert into public.ih_scan_logs(session_id,team_id,qr_code_id,scan_result,detail)
    values(v_ctx.session_id,v_ctx.team_id,null,'player_ok',
      jsonb_build_object('player_number',v_player_qr.player_number,'color',v_player_qr.color_code));

    return jsonb_build_object(
      'ok',true,'code','player_ok','color_code',v_player_qr.color_code,
      'ride_name',v_ride_name,'message','Silakan menuju wahana yang ditampilkan, lalu scan QR wahana.'
    );
  end if;

  select * into v_ride_qr
  from public.ih_qr_codes
  where token_hash=v_hash and session_id=v_ctx.session_id
    and qr_type='ride' and active=true;

  if not found then
    insert into public.ih_scan_logs(session_id,team_id,qr_code_id,scan_result,detail)
    values(v_ctx.session_id,v_ctx.team_id,null,'invalid','{"reason":"unknown_qr"}'::jsonb);
    return jsonb_build_object('ok',false,'code','invalid_qr','message','QR tidak dikenal atau bukan QR wahana untuk batch ini.');
  end if;

  select * into v_progress
  from public.ih_team_progress
  where team_id=v_ctx.team_id and status='player_found'
  for update;

  if not found then
    return jsonb_build_object('ok',false,'code','scan_player_first','message','Scan QR pemain terlebih dahulu untuk membuka petunjuk wahana.');
  end if;

  if not v_ride_qr.is_correct then
    insert into public.ih_scan_logs(session_id,team_id,qr_code_id,scan_result,detail)
    values(v_ctx.session_id,v_ctx.team_id,v_ride_qr.id,'decoy',
      jsonb_build_object('color',v_progress.color_code));
    return jsonb_build_object('ok',false,'code','decoy','message',coalesce(v_ride_qr.decoy_message,'QR ini pengecoh. Cari QR wahana yang sesuai.'));
  end if;

  if v_ride_qr.ride_id is distinct from v_progress.assigned_ride_id then
    insert into public.ih_scan_logs(session_id,team_id,qr_code_id,scan_result,detail)
    values(v_ctx.session_id,v_ctx.team_id,v_ride_qr.id,'wrong_ride',
      jsonb_build_object('color',v_progress.color_code));
    update public.ih_team_progress
    set status='waiting',player_scanned_at=null,updated_at=now()
    where id=v_progress.id;
    return jsonb_build_object('ok',false,'code','wrong_ride','message','QR wahana belum sesuai. Scan QR pemain lagi untuk melihat tujuan.');
  end if;

  select letter into v_letter
  from public.ih_puzzle_letters
  where session_id=v_ctx.session_id and color_code=v_progress.color_code;

  if v_letter is null then
    return jsonb_build_object('ok',false,'code','letter_not_configured','message','Huruf untuk warna ini belum dikonfigurasi.');
  end if;

  update public.ih_team_progress
  set status='letter_found',ride_scanned_at=now(),letter_received=v_letter,updated_at=now()
  where id=v_progress.id;

  insert into public.ih_scan_logs(session_id,team_id,qr_code_id,scan_result,detail)
  values(v_ctx.session_id,v_ctx.team_id,v_ride_qr.id,'ride_ok',
    jsonb_build_object('color',v_progress.color_code));

  return jsonb_build_object('ok',true,'code','ride_ok','color_code',v_progress.color_code,
    'letter',v_letter,'message','Berhasil! Huruf berhasil dikumpulkan.');
end;
$$;

drop function if exists public.ih_submit_answer(text,text,text);
create function public.ih_submit_answer(
  p_login_token text,p_animal_answer text,p_impostor_color_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ctx record;
  v_answer text;
  v_impostor text;
  v_elapsed integer;
  v_correct boolean;
  v_vouchers_created integer:=0;
begin
  select * into v_ctx from public.ih_participant_context(p_login_token);
  if not found then
    return jsonb_build_object('ok',false,'message','Sesi login berakhir. Silakan login kembali.');
  end if;
  perform 1 from public.ih_teams where id=v_ctx.team_id for update;

  if v_ctx.session_status<>'running' then
    return jsonb_build_object('ok',false,'message','Permainan tidak sedang berjalan.');
  end if;
  if exists(select 1 from public.ih_submissions where team_id=v_ctx.team_id) then
    return jsonb_build_object('ok',false,'message','Jawaban tim ini sudah tercatat satu kali.');
  end if;
  if (select count(*) from public.ih_team_progress
      where team_id=v_ctx.team_id and status='letter_found')<>6 then
    return jsonb_build_object('ok',false,'message','Kumpulkan keenam huruf terlebih dahulu.');
  end if;

  select animal_answer,impostor_color_code into v_answer,v_impostor
  from public.ih_puzzle_config
  where session_id=v_ctx.session_id and configured=true;
  if v_answer is null then
    raise exception 'Konfigurasi jawaban batch belum tersedia.';
  end if;

  v_correct := upper(trim(p_animal_answer))=v_answer
           and upper(trim(p_impostor_color_code))=v_impostor;

  select greatest(0,floor(extract(epoch from (now()-game_started_at)))::integer)
    into v_elapsed
  from public.ih_game_settings where session_id=v_ctx.session_id;

  insert into public.ih_submissions(
    session_id,team_id,animal_answer,impostor_color_code,is_correct,elapsed_seconds
  ) values (
    v_ctx.session_id,v_ctx.team_id,upper(trim(p_animal_answer)),
    upper(trim(p_impostor_color_code)),v_correct,v_elapsed
  );

  -- New event rule: every team that submits after collecting all six letters
  -- receives food vouchers, whether its final answer is correct or not.
  v_vouchers_created := public.ih_issue_team_food_vouchers(v_ctx.team_id);

  return jsonb_build_object(
    'ok',true,'correct',v_correct,'vouchers_created',v_vouchers_created,
    'message',case when v_correct
      then 'Jawaban benar! Voucher makanan tim sudah diterbitkan.'
      else 'Jawaban tercatat. Voucher makanan tim sudah diterbitkan.'
    end
  );
end;
$$;

-- Each participant can retrieve only their own voucher after submitting.
drop function if exists public.ih_get_food_voucher(text,text);
create or replace function public.ih_get_my_food_voucher(p_login_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ctx record;
  v_voucher public.ih_food_vouchers%rowtype;
begin
  select * into v_ctx from public.ih_participant_context(p_login_token);
  if not found then
    return jsonb_build_object('ok',false,'message','Sesi login berakhir. Silakan login kembali.');
  end if;
  select * into v_voucher
  from public.ih_food_vouchers
  where attendee_id=v_ctx.attendee_id and team_id=v_ctx.team_id;
  if not found then
    return jsonb_build_object('ok',false,'message','Voucher belum diterbitkan. Kirim jawaban akhir terlebih dahulu.');
  end if;
  return jsonb_build_object(
    'ok',true,'token',v_voucher.qr_token,
    'participant_name',v_ctx.participant_name,
    'nid',(select nid from public.attendees where id=v_ctx.attendee_id),
    'batch',v_ctx.batch_code,'team_code',v_ctx.team_code,
    'status',case when v_voucher.redeemed_at is null then 'active' else 'redeemed' end,
    'redeemed_at',v_voucher.redeemed_at
  );
end;
$$;

create or replace function public.ih_redeem_food_voucher(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  v_person record;
  v_user_id uuid:=auth.uid();
begin
  if v_user_id is null or not public.is_admin() then
    return jsonb_build_object('ok',false,'code','not_authorized','message','Akses hanya untuk Admin.');
  end if;
  if coalesce(length(p_token),0)<>64 then
    return jsonb_build_object('ok',false,'code','invalid_qr','message','QR voucher tidak valid.');
  end if;

  update public.ih_food_vouchers
  set redeemed_at=now(),redeemed_by=v_user_id
  where qr_token=p_token and redeemed_at is null
  returning id,attendee_id,team_id,session_id,redeemed_at into v_row;

  if found then
    select a.full_name,a.nid,a.batch,t.team_code into v_person
    from public.attendees a join public.ih_teams t on t.id=v_row.team_id
    where a.id=v_row.attendee_id;
    insert into public.ih_food_voucher_redemption_logs(
      voucher_id,attendee_id,team_id,session_id,redeemed_at,redeemed_by
    ) values(v_row.id,v_row.attendee_id,v_row.team_id,v_row.session_id,v_row.redeemed_at,v_user_id);
    return jsonb_build_object(
      'ok',true,'code','redeemed','message','Voucher berhasil ditukar.',
      'voucher_id',v_row.id,'redeemed_at',v_row.redeemed_at,
      'participant_name',v_person.full_name,'nid',v_person.nid,
      'batch',v_person.batch,'team_code',v_person.team_code
    );
  end if;
  if exists(select 1 from public.ih_food_vouchers where qr_token=p_token) then
    return jsonb_build_object('ok',false,'code','already_redeemed','message','Voucher ini sudah pernah ditukar.');
  end if;
  return jsonb_build_object('ok',false,'code','invalid_qr','message','QR voucher tidak ditemukan.');
end;
$$;

create or replace function public.ih_food_voucher_summary(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Akses hanya untuk Admin.';
  end if;
  return jsonb_build_object(
    'total',(select count(*) from public.ih_food_vouchers where session_id=p_session_id),
    'redeemed',(select count(*) from public.ih_food_vouchers where session_id=p_session_id and redeemed_at is not null),
    'active',(select count(*) from public.ih_food_vouchers where session_id=p_session_id and redeemed_at is null)
  );
end;
$$;

create or replace function public.ih_start_game(p_session_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_started timestamptz;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Akses hanya untuk Admin.';
  end if;
  perform 1 from public.ih_game_sessions where id=p_session_id for update;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  if (select status from public.ih_game_sessions where id=p_session_id)<>'draft' then
    raise exception 'Sesi harus berstatus draft untuk dimulai.';
  end if;
  if (select count(*) from public.ih_qr_codes
      where session_id=p_session_id and qr_type='ride' and active=true)<>18 then
    raise exception 'Harus tersedia tepat 18 QR wahana aktif untuk batch ini.';
  end if;
  if (select count(*) from public.ih_shared_player_qr_codes where active=true)<>18 then
    raise exception 'Set QR pemain bersama harus berisi tepat 18 QR aktif.';
  end if;
  if (select count(*) from public.ih_team_progress p
      join public.ih_teams t on t.id=p.team_id where t.session_id=p_session_id)<>108 then
    raise exception 'Progres 108 misi belum tersedia.';
  end if;
  v_started:=now();
  update public.ih_game_settings
  set game_started_at=v_started,game_ended_at=null,updated_at=now()
  where session_id=p_session_id;
  update public.ih_game_sessions
  set status='running',updated_at=now() where id=p_session_id;
  return v_started;
end;
$$;

-- Disable legacy QR issuing; the 18 shared player QR images in the CIH archive are the master set.
create or replace function public.ih_issue_qr_tokens(p_session_id uuid)
returns table(qr_type text,qr_label text,token text,qr_url text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Akses hanya untuk Admin.';
  end if;
  raise exception 'Penerbitan QR pemain dihapus. Gunakan 18 QR master CIH yang sudah disediakan. QR wahana yang lama tetap dipakai.';
end;
$$;

revoke all on function public.ih_participant_login(text,text) from public;
revoke all on function public.ih_get_team_state(text) from public;
revoke all on function public.ih_scan_qr(text,text) from public;
revoke all on function public.ih_submit_answer(text,text,text) from public;
revoke all on function public.ih_get_my_food_voucher(text) from public;
revoke all on function public.ih_redeem_food_voucher(text) from public;
revoke all on function public.ih_food_voucher_summary(uuid) from public;
revoke all on function public.ih_start_game(uuid) from public;
revoke all on function public.ih_issue_qr_tokens(uuid) from public;

grant execute on function public.ih_participant_login(text,text) to anon,authenticated;
grant execute on function public.ih_get_team_state(text) to anon,authenticated;
grant execute on function public.ih_scan_qr(text,text) to anon,authenticated;
grant execute on function public.ih_submit_answer(text,text,text) to anon,authenticated;
grant execute on function public.ih_get_my_food_voucher(text) to anon,authenticated;
grant execute on function public.ih_redeem_food_voucher(text) to authenticated;
grant execute on function public.ih_food_voucher_summary(uuid) to authenticated;
grant execute on function public.ih_start_game(uuid) to authenticated;
grant execute on function public.ih_issue_qr_tokens(uuid) to authenticated;

commit;
