-- =====================================================================
--  Migración 004 · Reorganizar asientos desde el panel
--  Ejecutar una sola vez en Supabase → SQL Editor → New query → Run
--
--  · Agrega UNA función de administración para mover a una persona de
--    silla. Si la silla destino está libre, se mueve; si está ocupada
--    (por otra familia o un apartado), se intercambian.
--  · No cambia invitaciones, códigos, lugares máximos ni confirmaciones:
--    cada familia conserva el mismo número de sillas, solo cambian cuáles.
--  · No modifica ningún dato al ejecutarse. Se puede ejecutar más de una vez.
-- =====================================================================

create or replace function public.admin_move_seat(
  p_password text, p_from_table int, p_from_seat int, p_to_table int, p_to_seat int)
returns void language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  a seats%rowtype;
  b seats%rowtype;
begin
  perform _require_admin(p_password);
  -- mismo candado que las confirmaciones: nunca choca con una familia confirmando
  perform pg_advisory_xact_lock(715151);

  if p_from_table = p_to_table and p_from_seat = p_to_seat then return; end if;

  select * into a from seats where table_no = p_from_table and seat_no = p_from_seat for update;
  select * into b from seats where table_no = p_to_table   and seat_no = p_to_seat   for update;
  if a.table_no is null or b.table_no is null then raise exception 'INVALID_SEATS'; end if;
  if a.invitation_id is null and a.reserved_label is null then raise exception 'EMPTY_SEAT'; end if;

  -- intercambio completo (si el destino está libre, el origen queda libre)
  update seats set invitation_id = b.invitation_id, reserved_label = b.reserved_label, updated_at = now()
  where table_no = a.table_no and seat_no = a.seat_no;

  update seats set invitation_id = a.invitation_id, reserved_label = a.reserved_label, updated_at = now()
  where table_no = b.table_no and seat_no = b.seat_no;
end $$;

revoke execute on function public.admin_move_seat(text, int, int, int, int) from public;
grant  execute on function public.admin_move_seat(text, int, int, int, int) to anon, authenticated;
