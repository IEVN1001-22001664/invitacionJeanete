-- =====================================================================
--  Migración 003 · Mesas de 12 asientos (120 lugares)
--  Ejecutar una sola vez en Supabase → SQL Editor → New query → Run
--
--  · NO borra ni mueve ningún asiento: los asientos 1–10 de cada mesa
--    conservan su número, su familia y sus apartados.
--  · Solo agrega los asientos 11 y 12 a cada una de las 10 mesas.
--  · Se puede ejecutar más de una vez sin duplicar nada.
-- =====================================================================

-- Permitir asientos del 1 al 12
alter table public.seats drop constraint if exists seats_seat_no_check;
alter table public.seats add constraint seats_seat_no_check check (seat_no between 1 and 12);

-- Agregar los asientos 11 y 12 a las 10 mesas (libres)
insert into public.seats (table_no, seat_no)
select t, s from generate_series(1, 10) t, generate_series(11, 12) s
on conflict do nothing;

-- Comprobación: debe decir total = 120 y los ocupados/apartados que ya tenías
select count(*)                as total,
       count(invitation_id)    as ocupados_por_invitados,
       count(reserved_label)   as apartados,
       count(*) filter (where invitation_id is null and reserved_label is null) as libres
from public.seats;
