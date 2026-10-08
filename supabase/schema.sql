-- =====================================================================
--  Invitación Camacho & Jeanette · Confirmación de asistencia y asientos
--  Ejecutar completo una sola vez en Supabase → SQL Editor → New query
-- =====================================================================
--  Diseño:
--   · Las tablas NO son accesibles desde la página (RLS activo, sin políticas).
--   · La página solo puede llamar a las funciones públicas de abajo, que
--     validan el código de la familia, la fecha límite y la disponibilidad.
--   · Todas las confirmaciones se procesan una a la vez (candado), así dos
--     familias nunca pueden quedarse con el mismo asiento.
--   · 10 mesas × 10 asientos = 100 lugares. La mesa presidencial va aparte.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
--  Tablas
-- ---------------------------------------------------------------------
create table if not exists public.invitations (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,                 -- va en el enlace: ?i=CODIGO
  name        text not null,                        -- "Familia Rodríguez Peña" o nombre completo
  max_seats   int  not null check (max_seats between 1 and 10),
  status      text not null default 'pending' check (status in ('pending','confirmed','declined')),
  attending   int  not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.seats (
  table_no       int not null check (table_no between 1 and 10),
  seat_no        int not null check (seat_no  between 1 and 10),
  invitation_id  uuid references public.invitations(id) on delete set null,
  reserved_label text,                               -- apartado por los novios (ej. "Padrinos")
  updated_at     timestamptz not null default now(),
  primary key (table_no, seat_no),
  check (not (invitation_id is not null and reserved_label is not null))
);

create table if not exists public.settings (
  key   text primary key,
  value text not null
);

-- 100 asientos
insert into public.seats (table_no, seat_no)
select t, s from generate_series(1,10) t, generate_series(1,10) s
on conflict do nothing;

-- Fecha límite: 15 de octubre de 2026, 23:59 hora del centro de México
insert into public.settings (key, value) values
  ('deadline', '2026-10-15 23:59:59-06')
on conflict (key) do nothing;

-- Cerrar las tablas al público
alter table public.invitations enable row level security;
alter table public.seats       enable row level security;
alter table public.settings    enable row level security;
revoke all on public.invitations, public.seats, public.settings from anon, authenticated;

-- ---------------------------------------------------------------------
--  Utilidades internas (no expuestas)
-- ---------------------------------------------------------------------
create or replace function public._is_admin(p_password text)
returns boolean language sql stable security definer
set search_path = public, extensions as $$
  select exists (
    select 1 from settings
    where key = 'admin_hash' and value = crypt(p_password, value)
  );
$$;

create or replace function public._require_admin(p_password text)
returns void language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  if not _is_admin(coalesce(p_password, '')) then
    raise exception 'NOT_ADMIN';
  end if;
end $$;

create or replace function public._new_code()
returns text language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';  -- sin 0/O, 1/I/L
  b bytea; c text;
begin
  loop
    b := gen_random_bytes(6);
    c := '';
    for i in 0..5 loop
      c := c || substr(alphabet, (get_byte(b, i) % length(alphabet)) + 1, 1);
    end loop;
    exit when not exists (select 1 from invitations where code = c);
  end loop;
  return c;
end $$;

create or replace function public._deadline()
returns timestamptz language sql stable security definer
set search_path = public as $$
  select value::timestamptz from settings where key = 'deadline';
$$;

-- ---------------------------------------------------------------------
--  Funciones públicas (las usa la invitación)
-- ---------------------------------------------------------------------

-- Datos de la invitación de una familia
create or replace function public.get_invitation(p_code text)
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare inv invitations%rowtype;
begin
  select * into inv from invitations where code = upper(trim(p_code));
  if not found then raise exception 'INVALID_CODE'; end if;

  return jsonb_build_object(
    'code',      inv.code,
    'name',      inv.name,
    'max',       inv.max_seats,
    'status',    inv.status,
    'attending', inv.attending,
    'deadline',  _deadline(),
    'open',      now() <= _deadline(),
    'seats',     coalesce((
                   select jsonb_agg(jsonb_build_object('t', table_no, 's', seat_no) order by table_no, seat_no)
                   from seats where invitation_id = inv.id), '[]'::jsonb)
  );
end $$;

-- Mapa de asientos: [[mesa, asiento, estado], ...]  estado: free | taken | mine
create or replace function public.get_seat_map(p_code text)
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare inv_id uuid;
begin
  select id into inv_id from invitations where code = upper(trim(p_code));
  if inv_id is null then raise exception 'INVALID_CODE'; end if;

  return (
    select jsonb_agg(jsonb_build_array(
             table_no, seat_no,
             case
               when invitation_id = inv_id then 'mine'
               when invitation_id is not null or reserved_label is not null then 'taken'
               else 'free'
             end) order by table_no, seat_no)
    from seats
  );
end $$;

-- Confirmar (o declinar) asistencia y asientos.
-- p_seats: [{"t":4,"s":3},{"t":4,"s":4}]   (vacío si no asistirán)
create or replace function public.submit_rsvp(p_code text, p_attending int, p_seats jsonb)
returns jsonb language plpgsql volatile security definer
set search_path = public as $$
declare
  inv      invitations%rowtype;
  n        int;
  valid_n  int;
  conflict jsonb;
begin
  -- Una confirmación a la vez: elimina cualquier carrera por el mismo asiento
  perform pg_advisory_xact_lock(715151);

  select * into inv from invitations where code = upper(trim(p_code)) for update;
  if not found then raise exception 'INVALID_CODE'; end if;
  if now() > _deadline() then raise exception 'DEADLINE_PASSED'; end if;
  if p_attending is null or p_attending < 0 or p_attending > inv.max_seats then
    raise exception 'INVALID_COUNT';
  end if;

  p_seats := coalesce(p_seats, '[]'::jsonb);
  n := jsonb_array_length(p_seats);
  if n <> p_attending then raise exception 'SEAT_COUNT_MISMATCH'; end if;

  -- Todos los asientos deben existir y no repetirse
  select count(distinct (x.table_no, x.seat_no)) into valid_n
  from jsonb_to_recordset(p_seats) as r(t int, s int)
  join seats x on x.table_no = r.t and x.seat_no = r.s;
  if valid_n <> n then raise exception 'INVALID_SEATS'; end if;

  -- Ninguno puede estar ocupado por otra familia o apartado
  select jsonb_agg(jsonb_build_object('t', x.table_no, 's', x.seat_no)) into conflict
  from jsonb_to_recordset(p_seats) as r(t int, s int)
  join seats x on x.table_no = r.t and x.seat_no = r.s
  where (x.invitation_id is not null and x.invitation_id <> inv.id)
     or x.reserved_label is not null;
  if conflict is not null then
    raise exception 'SEAT_TAKEN' using detail = conflict::text;
  end if;

  -- Liberar los asientos anteriores de la familia y asignar los nuevos
  update seats set invitation_id = null, updated_at = now()
  where invitation_id = inv.id;

  update seats x set invitation_id = inv.id, updated_at = now()
  from jsonb_to_recordset(p_seats) as r(t int, s int)
  where x.table_no = r.t and x.seat_no = r.s;

  update invitations
  set status    = case when p_attending = 0 then 'declined' else 'confirmed' end,
      attending = p_attending,
      updated_at = now()
  where id = inv.id;

  return get_invitation(inv.code);
end $$;

-- ---------------------------------------------------------------------
--  Funciones de administración (requieren la contraseña de admin)
-- ---------------------------------------------------------------------

-- Todo de un vistazo: invitaciones, asientos y totales
create or replace function public.admin_overview(p_password text)
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform _require_admin(p_password);
  return jsonb_build_object(
    'deadline', _deadline(),
    'invitations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', i.code, 'name', i.name, 'max', i.max_seats,
        'status', i.status, 'attending', i.attending, 'updated_at', i.updated_at,
        'seats', coalesce((select jsonb_agg(jsonb_build_object('t', s.table_no, 's', s.seat_no) order by s.table_no, s.seat_no)
                           from seats s where s.invitation_id = i.id), '[]'::jsonb)
      ) order by i.created_at)
      from invitations i), '[]'::jsonb),
    'seats', (
      select jsonb_agg(jsonb_build_object(
        't', s.table_no, 's', s.seat_no,
        'who', coalesce(i.name, s.reserved_label),
        'kind', case when i.id is not null then 'guest' when s.reserved_label is not null then 'reserved' else 'free' end
      ) order by s.table_no, s.seat_no)
      from seats s left join invitations i on i.id = s.invitation_id)
  );
end $$;

create or replace function public.admin_create_invitation(p_password text, p_name text, p_max int)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare c text;
begin
  perform _require_admin(p_password);
  c := _new_code();
  insert into invitations (code, name, max_seats) values (c, trim(p_name), p_max);
  return jsonb_build_object('code', c, 'name', trim(p_name), 'max', p_max);
end $$;

create or replace function public.admin_update_invitation(p_password text, p_code text, p_name text, p_max int)
returns void language plpgsql volatile security definer
set search_path = public, extensions as $$
declare inv invitations%rowtype;
begin
  perform _require_admin(p_password);
  select * into inv from invitations where code = upper(trim(p_code)) for update;
  if not found then raise exception 'INVALID_CODE'; end if;
  if p_max < inv.attending then raise exception 'MAX_BELOW_ATTENDING'; end if;
  update invitations set name = trim(p_name), max_seats = p_max, updated_at = now() where id = inv.id;
end $$;

create or replace function public.admin_delete_invitation(p_password text, p_code text)
returns void language plpgsql volatile security definer
set search_path = public, extensions as $$
begin
  perform _require_admin(p_password);
  perform pg_advisory_xact_lock(715151);
  delete from invitations where code = upper(trim(p_code));  -- sus asientos se liberan solos
end $$;

-- Apartar (p_label = 'Padrinos') o liberar (p_label = null) un asiento
create or replace function public.admin_set_reserved(p_password text, p_table int, p_seat int, p_label text)
returns void language plpgsql volatile security definer
set search_path = public, extensions as $$
begin
  perform _require_admin(p_password);
  perform pg_advisory_xact_lock(715151);
  if exists (select 1 from seats where table_no = p_table and seat_no = p_seat and invitation_id is not null) then
    raise exception 'SEAT_TAKEN';
  end if;
  update seats set reserved_label = nullif(trim(p_label), ''), updated_at = now()
  where table_no = p_table and seat_no = p_seat;
end $$;

-- Quitar un asiento a una familia (por ejemplo, si te avisan por WhatsApp)
create or replace function public.admin_release_seat(p_password text, p_table int, p_seat int)
returns void language plpgsql volatile security definer
set search_path = public, extensions as $$
declare inv_id uuid;
begin
  perform _require_admin(p_password);
  perform pg_advisory_xact_lock(715151);
  select invitation_id into inv_id from seats where table_no = p_table and seat_no = p_seat;
  if inv_id is null then return; end if;

  update seats set invitation_id = null, updated_at = now()
  where table_no = p_table and seat_no = p_seat;

  -- recalcular cuántos asisten de esa familia
  update invitations i
  set attending = (select count(*) from seats s where s.invitation_id = i.id),
      status    = case when exists (select 1 from seats s where s.invitation_id = i.id) then i.status else 'pending' end,
      updated_at = now()
  where i.id = inv_id;
end $$;

-- ---------------------------------------------------------------------
--  Permisos: la página (rol anon) solo puede ejecutar estas funciones
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.get_invitation(text)                          to anon, authenticated;
grant execute on function public.get_seat_map(text)                            to anon, authenticated;
grant execute on function public.submit_rsvp(text, int, jsonb)                 to anon, authenticated;
grant execute on function public.admin_overview(text)                          to anon, authenticated;
grant execute on function public.admin_create_invitation(text, text, int)      to anon, authenticated;
grant execute on function public.admin_update_invitation(text, text, text, int) to anon, authenticated;
grant execute on function public.admin_delete_invitation(text, text)           to anon, authenticated;
grant execute on function public.admin_set_reserved(text, int, int, text)      to anon, authenticated;
grant execute on function public.admin_release_seat(text, int, int)            to anon, authenticated;
