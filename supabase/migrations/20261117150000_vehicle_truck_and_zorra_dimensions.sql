-- Largo y ancho del camión y de su zorra. Ancho estándar de la flota: 2,40 m.
alter table public.logistics_vehicles
  add column if not exists zorra_length_m numeric(7,2) check (zorra_length_m is null or zorra_length_m > 0),
  add column if not exists zorra_width_m numeric(7,2) check (zorra_width_m is null or zorra_width_m > 0);

update public.logistics_vehicles set length_m = 7.50, width_m = 2.40, zorra_length_m = 8.00, zorra_width_m = 2.40 where id = 'howo';
update public.logistics_vehicles set length_m = 7.10, width_m = 2.40, zorra_length_m = 8.00, zorra_width_m = 2.40 where id = 'vw_camion';
update public.logistics_vehicles set length_m = 14.50, width_m = 2.40, zorra_length_m = null, zorra_width_m = null where id = 'vw_tractor';
update public.logistics_vehicles set length_m = 5.50, width_m = 2.40, zorra_length_m = 10.00, zorra_width_m = 2.40 where id = 'internacional';

insert into public.logistics_vehicles(id, name, length_m, width_m)
values ('ford', 'Ford', 5.10, 2.40)
on conflict (id) do nothing;
