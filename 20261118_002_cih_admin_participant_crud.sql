-- CIH unified Admin participant management
-- Run in Supabase SQL Editor after the participant-flow migration.
-- Uses the existing single admin_users allow-list through public.is_admin().

begin;

create or replace function public.ih_admin_save_participant(
  p_username text,
  p_nid text,
  p_batch_code text,
  p_team_id uuid,
  p_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_username text := upper(trim(coalesce(p_username,'')));
  v_nid text := upper(trim(coalesce(p_nid,'')));
  v_batch text := trim(coalesce(p_batch_code,''));
  v_attendee public.attendees%rowtype;
  v_team public.ih_teams%rowtype;
  v_session public.ih_game_sessions%rowtype;
  v_old_team_id uuid;
  v_is_new boolean := false;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Akses hanya untuk Admin.';
  end if;

  if v_username !~ '^B[12]-T(0[1-9]|1[0-8])-M[0-9]{2}$' then
    raise exception 'Format username TIM tidak valid. Contoh: B1-T01-M01.';
  end if;
  if v_nid = '' or length(v_nid) < 4 then
    raise exception 'NID wajib diisi dan harus valid.';
  end if;
  if v_batch not in ('Batch 1','Batch 2') then
    raise exception 'Batch harus Batch 1 atau Batch 2.';
  end if;
  if (split_part(v_username,'-',1)='B1' and v_batch<>'Batch 1')
     or (split_part(v_username,'-',1)='B2' and v_batch<>'Batch 2') then
    raise exception 'Prefix username TIM tidak sesuai dengan batch.';
  end if;

  select * into v_team
  from public.ih_teams
  where id=p_team_id
  for update;
  if not found then raise exception 'Tim tujuan tidak ditemukan.'; end if;

  select * into v_session
  from public.ih_game_sessions
  where id=v_team.session_id;
  if not found or v_session.batch_code<>v_batch then
    raise exception 'Tim tujuan tidak sesuai dengan batch peserta.';
  end if;

  select * into v_attendee
  from public.attendees
  where upper(trim(nid))=v_nid
  for update;

  if found then
    v_old_team_id := (
      select team_id from public.ih_participant_accounts
      where attendee_id=v_attendee.id
    );
    if v_old_team_id is not null and v_old_team_id<>p_team_id and (
      exists(select 1 from public.ih_scan_logs where team_id=v_old_team_id)
      or exists(select 1 from public.ih_submissions where team_id=v_old_team_id)
      or exists(select 1 from public.ih_food_vouchers where team_id=v_old_team_id)
    ) then
      raise exception 'Peserta tidak dapat dipindahkan karena tim asal sudah memiliki riwayat permainan atau voucher.';
    end if;

    update public.attendees
    set batch=v_batch,
        active=coalesce(p_active,true),
        updated_at=now()
    where id=v_attendee.id
    returning * into v_attendee;
  else
    v_is_new := true;
    insert into public.attendees(nid,full_name,batch,vehicle,active)
    values(v_nid,v_username,v_batch,'Belum ditentukan',coalesce(p_active,true))
    returning * into v_attendee;
  end if;

  if exists(
    select 1 from public.ih_participant_accounts
    where username=v_username and attendee_id<>v_attendee.id
  ) then
    raise exception 'Username TIM sudah digunakan peserta lain.';
  end if;

  if coalesce(p_active,true) then
    if v_old_team_id is distinct from p_team_id then
      delete from public.ih_team_members
      where attendee_id=v_attendee.id;
      insert into public.ih_team_members(attendee_id,team_id)
      values(v_attendee.id,p_team_id)
      on conflict (attendee_id) do update set team_id=excluded.team_id;
    end if;

    insert into public.ih_participant_accounts
      (username,attendee_id,team_id,password_hash,active,updated_at)
    values (
      v_username,v_attendee.id,p_team_id,
      extensions.crypt(v_nid,extensions.gen_salt('bf')),
      true,now()
    )
    on conflict (attendee_id) do update
      set username=excluded.username,
          team_id=excluded.team_id,
          password_hash=excluded.password_hash,
          active=true,
          updated_at=now();
  else
    update public.ih_participant_accounts
    set active=false,updated_at=now()
    where attendee_id=v_attendee.id;
  end if;

  return jsonb_build_object(
    'ok',true,
    'created',v_is_new,
    'username',v_username,
    'batch',v_batch,
    'active',coalesce(p_active,true),
    'message',case when v_is_new then 'Peserta berhasil ditambahkan.' else 'Data peserta berhasil diperbarui.' end
  );
end;
$$;

revoke all on function public.ih_admin_save_participant(text,text,text,uuid,boolean) from public, anon;
grant execute on function public.ih_admin_save_participant(text,text,text,uuid,boolean) to authenticated;


create or replace function public.ih_admin_list_participants()
returns table(
  attendee_id uuid,
  username text,
  nid text,
  batch text,
  active boolean,
  team_id uuid,
  team_code text,
  team_name text
)
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
    select a.id, coalesce(pa.username,''), a.nid, a.batch, a.active,
           tm.team_id, t.team_code, t.team_name
    from public.attendees a
    left join public.ih_participant_accounts pa on pa.attendee_id=a.id
    left join public.ih_team_members tm on tm.attendee_id=a.id
    left join public.ih_teams t on t.id=tm.team_id
    order by a.batch, coalesce(pa.username,''), a.nid;
end;
$$;
revoke all on function public.ih_admin_list_participants() from public, anon;
grant execute on function public.ih_admin_list_participants() to authenticated;


commit;
