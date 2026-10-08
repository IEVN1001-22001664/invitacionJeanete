-- =====================================================================
--  Migración 002 · Solicitudes de lugares adicionales
--  Ejecutar una sola vez en Supabase → SQL Editor → New query → Run
--  No borra ni modifica invitaciones ni asientos existentes.
-- =====================================================================

create table if not exists public.seat_requests (
  id            bigserial primary key,
  invitation_id uuid not null references public.invitations(id) on delete cascade,
  extra         int  not null check (extra between 1 and 5),
  note          text,
  status        text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz
);

alter table public.seat_requests enable row level security;
revoke all on public.seat_requests from anon, authenticated;
revoke all on sequence public.seat_requests_id_seq from anon, authenticated;

-- ---------------------------------------------------------------------
--  La invitación ahora también informa si hay una solicitud pendiente
-- ---------------------------------------------------------------------
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
                   from seats where invitation_id = inv.id), '[]'::jsonb),
    'request',   (select jsonb_build_object('extra', r.extra, 'status', r.status)
                  from seat_requests r where r.invitation_id = inv.id
                  order by r.created_at desc limit 1)
  );
end $$;

-- ---------------------------------------------------------------------
--  Pública: una familia pide lugares adicionales
-- ---------------------------------------------------------------------
create or replace function public.request_more_seats(p_code text, p_extra int, p_note text)
returns jsonb language plpgsql volatile security definer
set search_path = public as $$
declare inv invitations%rowtype;
begin
  select * into inv from invitations where code = upper(trim(p_code));
  if not found then raise exception 'INVALID_CODE'; end if;
  if now() > _deadline() then raise exception 'DEADLINE_PASSED'; end if;
  if p_extra is null or p_extra < 1 or p_extra > 5 then raise exception 'INVALID_COUNT'; end if;
  if exists (select 1 from seat_requests where invitation_id = inv.id and status = 'pending') then
    raise exception 'REQUEST_PENDING';
  end if;

  insert into seat_requests (invitation_id, extra, note)
  values (inv.id, p_extra, nullif(left(trim(coalesce(p_note, '')), 300), ''));

  return get_invitation(inv.code);
end $$;

-- ---------------------------------------------------------------------
--  Administración
-- ---------------------------------------------------------------------
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
      from seats s left join invitations i on i.id = s.invitation_id),
    'requests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'code', i.code, 'name', i.name, 'max', i.max_seats,
        'extra', r.extra, 'note', r.note, 'status', r.status, 'created_at', r.created_at
      ) order by (r.status = 'pending') desc, r.created_at desc)
      from seat_requests r join invitations i on i.id = r.invitation_id), '[]'::jsonb)
  );
end $$;

-- Aprobar suma los lugares extra al máximo de la invitación (tope 10)
create or replace function public.admin_resolve_request(p_password text, p_id bigint, p_approve boolean)
returns void language plpgsql volatile security definer
set search_path = public, extensions as $$
declare r seat_requests%rowtype;
begin
  perform _require_admin(p_password);
  select * into r from seat_requests where id = p_id for update;
  if not found or r.status <> 'pending' then raise exception 'INVALID_REQUEST'; end if;

  if p_approve then
    update invitations set max_seats = least(max_seats + r.extra, 10), updated_at = now()
    where id = r.invitation_id;
  end if;

  update seat_requests
  set status = case when p_approve then 'approved' else 'rejected' end, resolved_at = now()
  where id = p_id;
end $$;

-- ---------------------------------------------------------------------
--  Permisos (Supabase da permiso automático a funciones nuevas: se ajusta)
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.get_invitation(text)                           to anon, authenticated;
grant execute on function public.get_seat_map(text)                             to anon, authenticated;
grant execute on function public.submit_rsvp(text, int, jsonb)                  to anon, authenticated;
grant execute on function public.request_more_seats(text, int, text)            to anon, authenticated;
grant execute on function public.admin_overview(text)                           to anon, authenticated;
grant execute on function public.admin_create_invitation(text, text, int)       to anon, authenticated;
grant execute on function public.admin_update_invitation(text, text, text, int) to anon, authenticated;
grant execute on function public.admin_delete_invitation(text, text)            to anon, authenticated;
grant execute on function public.admin_set_reserved(text, int, int, text)       to anon, authenticated;
grant execute on function public.admin_release_seat(text, int, int)             to anon, authenticated;
grant execute on function public.admin_resolve_request(text, bigint, boolean)   to anon, authenticated;
