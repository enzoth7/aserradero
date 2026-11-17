-- Limpieza de conceptos que ya no se usan:
--   * código "Zeta": el código del producto queda en products.code (y desaparece de client_products y orders);
--   * puntos de control (client_product_controls, treatment_control_checks) y el estado "rejected" de los lotes de HT;
--   * catálogo de origen (Palbin / Pamer): products.source_catalog, source_code, treatment y las columnas sueltas
--     de clasificación (model, reinforcement, board_count, quality, finish, heat_treatment);
--   * importaciones de stock viejas (stock_import_runs / stock_import_rows) y el movimiento "opening_balance";
--   * versiones antiguas de funciones que solo existían por los puntos anteriores;
--   * el nombre viejo de la marca interna "deleting_order" y textos históricos con "Marcado".
-- Las funciones que cambian de firma pasan a una versión nueva (v8, v6, v3, v2); la aplicación llama a las nuevas.

-- 1. Textos históricos con nombres viejos ------------------------------------------------------------------
update public.order_lines set product = replace(replace(product, ' · Sin marcado', ' · Sin HT'), ' · Marcado', ' · Con HT') where product like '%arcado%';
update public.order_changes set note = replace(replace(note, ' · Sin marcado', ' · Sin HT'), ' · Marcado', ' · Con HT') where note like '%arcado%';
update public.capacity_daily_adjustments set responsible = 'Operación' where responsible = 'Ecoase';

-- 2. Puntos de control --------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from public.treatment_batches where status = 'rejected') then
    raise exception 'Hay lotes de HT rechazados; resuélvalos antes de quitar ese estado.';
  end if;
end $$;

drop table public.treatment_control_checks;
drop table public.client_product_controls;

alter table public.treatment_batches drop constraint treatment_batches_status_check;
alter table public.treatment_batches add constraint treatment_batches_status_check check (status in ('posted', 'reversal'));

-- 3. Importaciones de stock viejas ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from public.stock_movements where import_row_id is not null or movement_type = 'opening_balance') then
    raise exception 'Hay movimientos de stock que vienen de una importación; no se pueden quitar.';
  end if;
end $$;

alter table public.stock_movements drop constraint stock_movements_semantics_check;
alter table public.stock_movements drop constraint stock_movements_movement_type_check;
alter table public.stock_movements drop constraint stock_movements_import_row_id_fkey;
alter table public.stock_movements drop column import_row_id;
drop table public.stock_import_rows;
drop table public.stock_import_runs;

alter table public.stock_movements add constraint stock_movements_movement_type_check check (movement_type in (
  'internal_production', 'supplier_receipt', 'production_receipt', 'treatment_out', 'treatment_in',
  'treatment_reversal_out', 'treatment_reversal_in', 'dispatch', 'return', 'waste', 'adjustment', 'reversal'));
alter table public.stock_movements add constraint stock_movements_semantics_check check (
  (movement_type in ('internal_production', 'supplier_receipt', 'return') and quantity > 0)
  or (movement_type = 'production_receipt' and quantity > 0 and production_allocation_id is not null)
  or (movement_type = 'treatment_out' and stock_state = 'pending_treatment' and quantity < 0 and treatment_batch_id is not null)
  or (movement_type = 'treatment_in' and stock_state = 'ready' and quantity > 0 and treatment_batch_id is not null)
  or (movement_type = 'treatment_reversal_out' and stock_state = 'ready' and quantity < 0 and treatment_batch_id is not null)
  or (movement_type = 'treatment_reversal_in' and stock_state = 'pending_treatment' and quantity > 0 and treatment_batch_id is not null)
  or (movement_type in ('dispatch', 'waste') and quantity < 0)
  or (movement_type in ('adjustment', 'reversal') and quantity <> 0));

-- 4. Productos: el código vive solo en products.code ---------------------------------------------------------
do $$
begin
  if exists (select 1 from public.products where nullif(trim(zeta_code), '') is not null group by upper(trim(zeta_code)) having count(*) > 1) then
    raise exception 'Hay códigos de producto repetidos; corríjalos antes de migrar.';
  end if;
end $$;

drop trigger products_sync_zeta_to_client_products on public.products;
drop function public.sync_product_zeta_to_client_products();
drop trigger client_products_set_zeta_from_catalog on public.client_products;
drop function public.set_client_product_zeta_from_catalog();

drop index public.client_products_client_zeta_unique;
alter table public.client_products drop constraint client_products_zeta_code_check;
alter table public.client_products drop column zeta_code;
alter table public.orders drop column zeta_code;

drop index public.products_internal_code_unique;
drop index public.products_source_catalog_code_unique;
alter table public.products rename column zeta_code to code;
alter table public.products
  drop column treatment,
  drop column source_catalog,
  drop column source_code,
  drop column model,
  drop column reinforcement,
  drop column board_count,
  drop column quality,
  drop column finish,
  drop column heat_treatment;
create unique index products_code_unique on public.products (upper(trim(code))) where nullif(trim(code), '') is not null;

-- 5. Funciones nuevas ---------------------------------------------------------------------------------------
create or replace function public.check_product_code_available(p_product_id text, p_code text)
returns boolean
language plpgsql
set search_path to 'public'
as $$
begin
  if exists (select 1 from public.products where id <> p_product_id and upper(trim(code)) = upper(trim(p_code))) then
    raise exception 'Ya existe otro producto con el código %.', upper(trim(p_code));
  end if;
  return true;
end; $$;

create or replace function public.create_catalog_product_v8(
  p_kind text, p_measure text, p_height_cm numeric, p_attributes jsonb, p_code text, p_stock_name text, p_client_ids text[]
)
returns text
language plpgsql
set search_path to 'public'
as $$
declare
  v_id text;
  v_code text := upper(nullif(trim(p_code), ''));
  v_client text;
  v_attrs jsonb;
  v_key text;
  v_twin text;
begin
  if p_kind not in ('Pallet', 'Piso', 'Bin') then raise exception 'El tipo indicado no es válido.'; end if;
  if v_code is null or v_code !~ '^[1-9][0-9]*$' then raise exception 'Indique un código numérico.'; end if;
  if nullif(trim(p_measure), '') is null then raise exception 'Indique la medida.'; end if;
  if p_height_cm is not null and p_height_cm <= 0 then raise exception 'La altura debe ser positiva.'; end if;
  v_attrs := public.clean_product_attributes(p_attributes);
  if exists (select 1 from public.products where upper(trim(code)) = v_code) then
    raise exception 'Ya existe un producto con el código %.', v_code;
  end if;
  v_key := public.product_identity_key(p_kind, p_measure, v_attrs);
  select coalesce(code, id) into v_twin from public.products where identity_key = v_key limit 1;
  if v_twin is not null then raise exception 'Ya existe un producto con esa clasificación (código %).', v_twin; end if;

  v_id := 'producto-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint || '-' || left(replace(gen_random_uuid()::text, '-', ''), 6);
  insert into public.products(id, kind, measure, height_cm, requires_treatment, code, stock_name, attributes, identity_key)
  values (v_id, p_kind, nullif(trim(p_measure), ''), case when p_kind = 'Pallet' then coalesce(p_height_cm, 10) else p_height_cm end,
    coalesce(v_attrs->>'tratamiento' like 'Con HT%', false), v_code, nullif(trim(p_stock_name), ''), v_attrs, v_key);
  foreach v_client in array coalesce(p_client_ids, array[]::text[]) loop
    insert into public.client_products(client_id, product_id, active, display_order)
    values (v_client, v_id, true, (select count(*) from public.client_products where client_id = v_client))
    on conflict (client_id, product_id) do update set active = true;
  end loop;
  return v_id;
end; $$;

create or replace function public.update_catalog_product_v6(
  p_id text, p_kind text, p_measure text, p_height_cm numeric, p_height_provided boolean, p_attributes jsonb, p_code text, p_stock_name text
)
returns text
language plpgsql
set search_path to 'public'
as $$
declare
  v_code text := upper(nullif(trim(p_code), ''));
  v_attrs jsonb;
  v_key text;
  v_twin text;
  v_id text;
begin
  if p_kind not in ('Pallet', 'Piso', 'Bin') then raise exception 'El tipo indicado no es válido.'; end if;
  if nullif(trim(p_measure), '') is null then raise exception 'Indique la medida.'; end if;
  if p_height_provided and p_height_cm is not null and p_height_cm <= 0 then raise exception 'La altura debe ser positiva.'; end if;
  v_attrs := public.clean_product_attributes(p_attributes);
  if v_code is not null and v_code !~ '^[1-9][0-9]*$' then raise exception 'Indique un código numérico.'; end if;
  if v_code is not null then perform public.check_product_code_available(p_id, v_code); end if;
  v_key := public.product_identity_key(p_kind, p_measure, v_attrs);
  select coalesce(code, id) into v_twin from public.products where identity_key = v_key and id <> p_id limit 1;
  if v_twin is not null then raise exception 'Ya existe un producto con esa clasificación (código %).', v_twin; end if;

  update public.products set
    kind = p_kind,
    measure = nullif(trim(p_measure), ''),
    height_cm = case when p_height_provided then case when p_kind = 'Pallet' then coalesce(p_height_cm, 10) else p_height_cm end else height_cm end,
    requires_treatment = coalesce(v_attrs->>'tratamiento' like 'Con HT%', false),
    attributes = v_attrs,
    identity_key = v_key,
    code = coalesce(v_code, code),
    stock_name = coalesce(nullif(trim(p_stock_name), ''), stock_name)
  where id = p_id returning id into v_id;
  if v_id is null then raise exception 'Producto no encontrado.'; end if;
  return v_id;
end; $$;

create or replace function public.create_client_product_master_v3(p_client_id text, p_product_id text, p_operational_name text)
returns bigint
language plpgsql
set search_path to 'public'
as $$
declare v_id bigint; v_code text;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then raise exception 'Cliente no encontrado.'; end if;
  select nullif(trim(code), '') into v_code from public.products where id = p_product_id;
  if not found then raise exception 'Producto no encontrado.'; end if;
  if v_code is null then raise exception 'El producto debe tener un código.'; end if;

  insert into public.client_products(client_id, product_id, operational_name, active)
  values (p_client_id, p_product_id, nullif(trim(p_operational_name), ''), true)
  returning id into v_id;
  return v_id;
end; $$;

create or replace function public.update_client_product_master_v2(p_id bigint, p_operational_name text, p_active boolean, p_display_order integer)
returns boolean
language plpgsql
set search_path to 'public'
as $$
declare v_product_id text; v_code text;
begin
  select product_id into v_product_id from public.client_products where id = p_id for update;
  if not found then raise exception 'Relación cliente-producto no encontrada.'; end if;
  select nullif(trim(code), '') into v_code from public.products where id = v_product_id;
  if v_code is null then raise exception 'El producto debe tener un código.'; end if;
  if p_display_order < 0 then raise exception 'El orden no puede ser negativo.'; end if;

  update public.client_products
  set operational_name = nullif(trim(p_operational_name), ''),
      active = p_active,
      display_order = p_display_order
  where id = p_id;
  return true;
end; $$;

create or replace function public.set_product_clients_v1(p_product_id text, p_client_ids text[])
returns boolean
language plpgsql
set search_path to 'public'
as $$
declare v_client text; v_link record;
begin
  if not exists (select 1 from public.products where id = p_product_id) then raise exception 'Producto no encontrado.'; end if;
  foreach v_client in array coalesce(p_client_ids, array[]::text[]) loop
    insert into public.client_products(client_id, product_id, active, display_order)
    values (v_client, p_product_id, true, (select count(*) from public.client_products where client_id = v_client))
    on conflict (client_id, product_id) do update set active = true;
  end loop;
  for v_link in select id from public.client_products where product_id = p_product_id and not (client_id = any(coalesce(p_client_ids, array[]::text[]))) loop
    if exists (select 1 from public.order_lines where client_product_id = v_link.id) then
      update public.client_products set active = false where id = v_link.id;
    else
      delete from public.client_product_assets where client_product_id = v_link.id;
      delete from public.client_products where id = v_link.id;
    end if;
  end loop;
  return true;
end; $$;

create or replace function public.record_treatment_batch_v2(
  p_product_id text, p_client_product_id bigint, p_order_line_id text, p_quantity integer,
  p_performed_at timestamptz, p_responsible text, p_note text
)
returns jsonb
language plpgsql
set search_path to 'public'
as $$
declare
  v_requires_treatment boolean;
  v_client_product_id bigint := p_client_product_id;
  v_line_product_id text;
  v_line_client_product_id bigint;
  v_batch_id bigint;
  v_transformation_id uuid := gen_random_uuid();
  v_pending_before integer := 0;
  v_ready_before integer := 0;
begin
  if p_quantity is null or p_quantity <= 0 then raise exception 'La cantidad debe ser mayor a cero.'; end if;
  if nullif(trim(p_responsible), '') is null then raise exception 'Indique quién realizó el tratamiento.'; end if;

  select requires_treatment into v_requires_treatment from public.products where id = p_product_id;
  if not found then raise exception 'Producto no encontrado.'; end if;
  if not v_requires_treatment then raise exception 'El producto no requiere HT.'; end if;

  if p_order_line_id is not null then
    select product_id, client_product_id into v_line_product_id, v_line_client_product_id
    from public.order_lines where id = p_order_line_id for share;
    if not found then raise exception 'Línea de pedido no encontrada.'; end if;
    if v_line_product_id is distinct from p_product_id then raise exception 'La línea no corresponde al producto seleccionado.'; end if;
    if v_line_client_product_id is null then raise exception 'La línea no tiene cliente/producto vinculado.'; end if;
    if p_client_product_id is not null and p_client_product_id <> v_line_client_product_id then raise exception 'La línea no corresponde al cliente/producto seleccionado.'; end if;
    v_client_product_id := v_line_client_product_id;
  end if;

  if v_client_product_id is not null and not exists (
    select 1 from public.client_products where id = v_client_product_id and product_id = p_product_id
  ) then raise exception 'El cliente/producto no coincide con el producto.'; end if;

  perform 1 from public.products where id = p_product_id for update;
  select coalesce(sum(quantity), 0) into v_pending_before
  from public.stock_movements where product_id = p_product_id and stock_state = 'pending_treatment';
  select coalesce(sum(quantity), 0) into v_ready_before
  from public.stock_movements where product_id = p_product_id and stock_state = 'ready';
  -- Si el stock pendiente no alcanza (producción sin registrar), se registra igual; el saldo queda negativo y la pantalla lo advierte.

  insert into public.treatment_batches(
    product_id, client_product_id, order_line_id, quantity, performed_at, responsible, status, note
  ) values (
    p_product_id, v_client_product_id, p_order_line_id, p_quantity, coalesce(p_performed_at, now()), trim(p_responsible), 'posted', nullif(trim(p_note), '')
  ) returning id into v_batch_id;

  insert into public.stock_movements(product_id, stock_state, quantity, movement_type, treatment_batch_id, transformation_id, performed_at, responsible, note)
  values
    (p_product_id, 'pending_treatment', -p_quantity, 'treatment_out', v_batch_id, v_transformation_id, coalesce(p_performed_at, now()), trim(p_responsible), nullif(trim(p_note), '')),
    (p_product_id, 'ready', p_quantity, 'treatment_in', v_batch_id, v_transformation_id, coalesce(p_performed_at, now()), trim(p_responsible), nullif(trim(p_note), ''));

  return jsonb_build_object(
    'batchId', v_batch_id,
    'status', 'posted',
    'transformationId', v_transformation_id,
    'previousPending', v_pending_before,
    'newPending', v_pending_before - p_quantity,
    'previousReady', v_ready_before,
    'newReady', v_ready_before + p_quantity
  );
end; $$;

-- Mismo nombre y firma que antes: se reemplaza el cuerpo (sin código Zeta ni "Marcado").
create or replace function public.create_operation_order_v5(p_lines jsonb, p_order_date date, p_requested_delivery_date date, p_production_date date, p_planned_date date, p_reference text, p_notes text, p_stage text, p_production_source text, p_producer_provider_id text, p_import_arrival_date date, p_required_operations text[], p_transport_source text, p_transport_provider_id text)
returns text
language plpgsql
set search_path to 'public'
as $$
declare
  v_item jsonb; v_link public.client_products%rowtype; v_client public.clients%rowtype; v_product public.products%rowtype;
  v_client_id text; v_id text; v_reference text; v_transport text; v_producer text; v_product_summary text := '';
  v_total integer := 0; v_quantity integer; v_position integer := 0; v_line_id text; v_shipment_id bigint;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Indique al menos una línea.'; end if;
  if p_order_date is null or p_requested_delivery_date is null or p_planned_date is null then raise exception 'Las fechas son obligatorias.'; end if;
  if p_stage not in ('negociacion','produccion','logistica','atrasado','pospuesto','cancelado','reorganizando') then raise exception 'Etapa inválida.'; end if;
  if p_production_source not in ('internal','sawmill','import') or p_transport_source not in ('internal','external') then raise exception 'Origen operativo inválido.'; end if;
  if cardinality(p_required_operations) = 0 or not (p_required_operations <@ array['assembly','treatment']::text[]) then raise exception 'Seleccione operaciones válidas.'; end if;
  if p_production_source = 'sawmill' and not exists (select 1 from public.providers where id = p_producer_provider_id and type = 'Aserradero') then raise exception 'Seleccione un aserradero registrado.'; end if;
  if p_production_source <> 'import' and p_production_date is null then raise exception 'Indique la fecha de producción.'; end if;
  if p_production_source = 'import' and (p_import_arrival_date is null or not exists (select 1 from public.providers where id = p_producer_provider_id and type = 'Importador')) then raise exception 'Seleccione un importador y fecha de llegada.'; end if;
  if p_transport_source = 'external' and not exists (select 1 from public.providers where id = p_transport_provider_id and type = 'Transporte') then raise exception 'Seleccione un transportista registrado.'; end if;

  for v_item in select * from jsonb_array_elements(p_lines) loop
    v_quantity := (v_item->>'quantity')::integer;
    if v_quantity is null or v_quantity <= 0 then raise exception 'Cada línea necesita una cantidad mayor a cero.'; end if;
    select * into v_link from public.client_products where id = (v_item->>'clientProductId')::bigint and active for share;
    if not found then raise exception 'Un producto no está habilitado.'; end if;
    if v_client_id is null then v_client_id := v_link.client_id; elsif v_client_id <> v_link.client_id then raise exception 'Todas las líneas deben pertenecer al mismo cliente.'; end if;
    select * into v_product from public.products where id = v_link.product_id;
    v_product_summary := concat_ws(' · ', nullif(v_product_summary, ''), coalesce(nullif(trim(v_link.operational_name), ''), concat_ws(' ', v_product.kind, v_product.measure)));
    v_total := v_total + v_quantity;
  end loop;

  select * into v_client from public.clients where id = v_client_id and active;
  if not found then raise exception 'El cliente no está disponible para pedidos.'; end if;
  select name into v_transport from public.providers where id = p_transport_provider_id;
  select name into v_producer from public.providers where id = p_producer_provider_id;
  v_transport := case when p_transport_source = 'internal' then 'Interno' else v_transport end;
  v_id := 'pedido-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint || '-' || left(replace(gen_random_uuid()::text, '-', ''), 6);
  select coalesce(nullif(trim(p_reference), ''), 'Pedido ' || (count(*) + 1)::text) into v_reference from public.orders;

  insert into public.orders(id, reference, client, product, requested, delivered, pending, status, status_label, stage,
    order_date, requested_delivery_date, planned_date, transport, supply, preparation, logistics, delivery, action,
    delivery_address, notes, source, production_source, producer_provider_id, production_date,
    import_arrival_date, required_operations, transport_source, transport_provider_id)
  values (v_id, v_reference, v_client.name, v_product_summary, v_total, 0, v_total, 'coordinacion', 'En coordinación', p_stage,
    p_order_date, p_requested_delivery_date, p_planned_date, v_transport,
    case p_production_source when 'internal' then 'Producción interna' when 'sawmill' then 'Produce ' || v_producer else 'Importación · llegada ' || p_import_arrival_date::text end,
    'Operaciones: ' || array_to_string(p_required_operations, ', '), v_transport || ' · entrega planificada', '0 de ' || v_total || ' entregados',
    'Preparar y coordinar la entrega.', v_client.address, nullif(trim(p_notes), ''), 'Alta con líneas, producción y viaje',
    p_production_source, p_producer_provider_id, p_production_date, p_import_arrival_date, p_required_operations, p_transport_source, p_transport_provider_id);

  insert into public.shipments(order_id, planned_date, status, transport_source, transport_provider_id)
  values (v_id, p_planned_date, 'planned', p_transport_source, p_transport_provider_id) returning id into v_shipment_id;

  for v_item in select * from jsonb_array_elements(p_lines) loop
    select * into v_link from public.client_products where id = (v_item->>'clientProductId')::bigint;
    select * into v_product from public.products where id = v_link.product_id;
    v_quantity := (v_item->>'quantity')::integer;
    v_line_id := v_id || '-' || (v_position + 1);
    insert into public.order_lines(id, order_id, product, product_id, client_product_id, quantity, requested_quantity, position)
    values (v_line_id, v_id, coalesce(nullif(trim(v_link.operational_name), ''), concat_ws(' · ', v_product.kind, coalesce(v_product.measure,'Sin medida'), case when v_product.requires_treatment then 'Con HT' else 'Sin HT' end)), v_product.id, v_link.id, v_quantity, v_quantity, v_position);
    insert into public.production_allocations(order_line_id, resource_id, planned_date, planned_quantity, status)
    values (v_line_id, case when p_production_source = 'internal' then 'internal' else p_producer_provider_id end,
      coalesce(p_production_date, p_import_arrival_date), v_quantity, case when p_stage = 'produccion' then 'confirmed' else 'draft' end);
    insert into public.shipment_lines(shipment_id, order_line_id, planned_quantity) values (v_shipment_id, v_line_id, v_quantity);
    v_position := v_position + 1;
  end loop;
  insert into public.shipment_events(shipment_id, event_type, next_status, next_date, responsible)
  values (v_shipment_id, 'created', 'planned', p_planned_date, 'Sistema');
  return v_id;
end; $$;

-- Mismo nombre y firma que antes: la marca interna de borrado pasa a llamarse app.deleting_order.
create or replace function public.prevent_shipment_event_changes()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if tg_op = 'DELETE' and current_setting('app.deleting_order', true) = 'on' then
    return old;
  end if;
  raise exception 'El historial de viajes es inmutable.';
end; $$;

create or replace function public.delete_operation_order_v1(p_order_id text)
returns boolean
language plpgsql
set search_path to 'public'
as $$
begin
  if not exists (select 1 from public.orders where id = p_order_id) then raise exception 'Pedido no encontrado.'; end if;
  if exists (
    select 1 from public.stock_movements sm
    where sm.order_line_id in (select id from public.order_lines where order_id = p_order_id)
       or sm.production_allocation_id in (select pa.id from public.production_allocations pa join public.order_lines ol on ol.id = pa.order_line_id where ol.order_id = p_order_id)
       or sm.shipment_line_id in (select sl.id from public.shipment_lines sl join public.shipments s on s.id = sl.shipment_id where s.order_id = p_order_id)
  ) or exists (
    select 1 from public.treatment_batches tb where tb.order_line_id in (select id from public.order_lines where order_id = p_order_id)
  ) then
    raise exception 'El pedido ya tiene movimientos de stock o marcados registrados. Cancelalo para conservar el historial.';
  end if;

  perform set_config('app.deleting_order', 'on', true);
  delete from public.stock_reservations where shipment_line_id in (select sl.id from public.shipment_lines sl join public.shipments s on s.id = sl.shipment_id where s.order_id = p_order_id);
  delete from public.shipment_events where shipment_id in (select id from public.shipments where order_id = p_order_id);
  delete from public.shipment_lines where shipment_id in (select id from public.shipments where order_id = p_order_id);
  delete from public.shipments where order_id = p_order_id;
  delete from public.production_allocations where order_line_id in (select id from public.order_lines where order_id = p_order_id);
  delete from public.orders where id = p_order_id;
  perform set_config('app.deleting_order', 'off', true);
  return true;
end; $$;

-- Igual que antes, sin la importación de stock y sin nombres viejos.
create or replace function public.delete_catalog_product_v2(p_id text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_orders integer; v_clients text; v_stock integer;
begin
  if not exists (select 1 from public.products where id = p_id) then raise exception 'Producto no encontrado.'; end if;
  select count(distinct ol.order_id), string_agg(distinct o.client, ', ') into v_orders, v_clients
  from public.order_lines ol join public.orders o on o.id = ol.order_id where ol.product_id = p_id;
  if v_orders > 0 then
    raise exception 'No se puede eliminar: el producto figura en % pedido(s) de %. Cancelá o eliminá esos pedidos primero.', v_orders, v_clients;
  end if;
  select (select count(*) from public.stock_movements where product_id = p_id) + (select count(*) from public.treatment_batches where product_id = p_id) + (select count(*) from public.stock_reservations where product_id = p_id) into v_stock;
  if v_stock > 0 then raise exception 'No se puede eliminar: el producto tiene movimientos de stock o de secadero registrados.'; end if;
  if exists (select 1 from public.production_allocations pa join public.production_capacity_rules r on r.id = pa.capacity_rule_id where r.product_id = p_id) then
    raise exception 'No se puede eliminar: hay producción confirmada con reglas de este producto.';
  end if;
  delete from public.production_capacity_rules where product_id = p_id;
  delete from public.client_product_assets where client_product_id in (select id from public.client_products where product_id = p_id);
  delete from public.client_products where product_id = p_id;
  delete from public.products where id = p_id;
  return p_id;
end; $$;

-- El productor interno ya no figura con un nombre propio en el historial de cambios.
create or replace function public.update_operation_order_v3(p_id text, p_planned_date date, p_requested integer, p_stage text, p_production_source text, p_producer_provider_id text, p_production_date date, p_import_arrival_date date, p_required_operations text[], p_transport_source text, p_transport_provider_id text)
returns text
language plpgsql
set search_path to 'public'
as $$
declare
  v_before public.orders%rowtype; v_after public.orders%rowtype; v_transport text;
  v_change_id uuid; v_position integer := 10;
begin
  select * into v_before from public.orders where id = p_id;
  if not found then raise exception 'Pedido no encontrado.'; end if;
  if p_production_source in ('internal','sawmill') and p_production_date is null then raise exception 'Indique la fecha de producción.'; end if;
  if p_production_source = 'sawmill' and not exists (select 1 from public.providers where id = p_producer_provider_id and type = 'Aserradero') then raise exception 'Seleccione un aserradero registrado.'; end if;
  if p_production_source = 'import' and (p_import_arrival_date is null or not exists (select 1 from public.providers where id = p_producer_provider_id and type = 'Importador')) then raise exception 'Seleccione importador y fecha prevista de llegada.'; end if;
  if p_transport_source = 'external' and not exists (select 1 from public.providers where id = p_transport_provider_id and type = 'Transporte') then raise exception 'Seleccione un transportista registrado.'; end if;
  if cardinality(p_required_operations) = 0 or not (p_required_operations <@ array['assembly','treatment']::text[]) then raise exception 'Operaciones inválidas.'; end if;
  select name into v_transport from public.providers where id = p_transport_provider_id;
  v_transport := case when p_transport_source = 'internal' then 'Interno' else v_transport end;
  perform public.update_operation_order(p_id, null, case when p_transport_source = 'external' then v_transport else null end, p_planned_date, p_requested, p_stage);
  select * into v_after from public.orders where id = p_id;
  if p_transport_source = 'internal' and v_after.transport <> 'Interno' then update public.orders set transport = 'Interno', logistics = 'Interno · entrega planificada' where id = p_id; end if;
  if v_before.production_source is distinct from p_production_source or v_before.producer_provider_id is distinct from p_producer_provider_id or v_before.production_date is distinct from p_production_date or v_before.import_arrival_date is distinct from p_import_arrival_date or v_before.required_operations is distinct from p_required_operations or v_before.transport_source is distinct from p_transport_source or v_before.transport_provider_id is distinct from p_transport_provider_id then
    insert into public.order_changes(order_id) values (p_id) returning id into v_change_id;
    if v_before.production_source is distinct from p_production_source then insert into public.order_change_items(change_id,field,from_value,to_value,position) values(v_change_id,'Origen de producción',v_before.production_source,p_production_source,v_position); v_position:=v_position+1; end if;
    if v_before.producer_provider_id is distinct from p_producer_provider_id then insert into public.order_change_items(change_id,field,from_value,to_value,position) values(v_change_id,'Productor',coalesce((select name from public.providers where id=v_before.producer_provider_id),'—'),coalesce((select name from public.providers where id=p_producer_provider_id),'Interno'),v_position); v_position:=v_position+1; end if;
    if v_before.production_date is distinct from p_production_date then insert into public.order_change_items(change_id,field,from_value,to_value,position) values(v_change_id,'Fecha de producción',coalesce(v_before.production_date::text,'—'),coalesce(p_production_date::text,'—'),v_position); v_position:=v_position+1; end if;
    if v_before.import_arrival_date is distinct from p_import_arrival_date then insert into public.order_change_items(change_id,field,from_value,to_value,position) values(v_change_id,'Llegada de importación',coalesce(v_before.import_arrival_date::text,'—'),coalesce(p_import_arrival_date::text,'—'),v_position); v_position:=v_position+1; end if;
    if v_before.required_operations is distinct from p_required_operations then insert into public.order_change_items(change_id,field,from_value,to_value,position) values(v_change_id,'Operaciones',array_to_string(v_before.required_operations,', '),array_to_string(p_required_operations,', '),v_position); v_position:=v_position+1; end if;
    if v_before.transport_source is distinct from p_transport_source then insert into public.order_change_items(change_id,field,from_value,to_value,position) values(v_change_id,'Origen del transporte',v_before.transport_source,p_transport_source,v_position); v_position:=v_position+1; end if;
    if v_before.transport_provider_id is distinct from p_transport_provider_id then insert into public.order_change_items(change_id,field,from_value,to_value,position) values(v_change_id,'Transportista',coalesce((select name from public.providers where id=v_before.transport_provider_id),'Interno'),coalesce((select name from public.providers where id=p_transport_provider_id),'Interno'),v_position); v_position:=v_position+1; end if;
  end if;
  update public.orders set
    production_source=p_production_source, producer_provider_id=p_producer_provider_id,
    production_date=p_production_date, import_arrival_date=p_import_arrival_date,
    required_operations=p_required_operations, transport_source=p_transport_source,
    transport_provider_id=p_transport_provider_id, transport=v_transport, updated_at=now()
  where id=p_id;
  return p_id;
end; $$;

-- 6. Permisos de las funciones nuevas: solo el servidor (igual que las anteriores) ---------------------------
revoke execute on function public.check_product_code_available(text, text) from public, anon, authenticated;
grant execute on function public.check_product_code_available(text, text) to service_role;
revoke execute on function public.create_catalog_product_v8(text, text, numeric, jsonb, text, text, text[]) from public, anon, authenticated;
grant execute on function public.create_catalog_product_v8(text, text, numeric, jsonb, text, text, text[]) to service_role;
revoke execute on function public.update_catalog_product_v6(text, text, text, numeric, boolean, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.update_catalog_product_v6(text, text, text, numeric, boolean, jsonb, text, text) to service_role;
revoke execute on function public.create_client_product_master_v3(text, text, text) from public, anon, authenticated;
grant execute on function public.create_client_product_master_v3(text, text, text) to service_role;
revoke execute on function public.record_treatment_batch_v2(text, bigint, text, integer, timestamptz, text, text) from public, anon, authenticated;
grant execute on function public.record_treatment_batch_v2(text, bigint, text, integer, timestamptz, text, text) to service_role;

-- 7. Versiones viejas que ya no usa nadie ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as signature
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = any (array[
        'check_product_combination_available', 'check_product_zeta_available',
        'create_catalog_product', 'create_catalog_product_v3', 'create_catalog_product_v4', 'create_catalog_product_v5',
        'create_catalog_product_v6', 'create_catalog_product_v7',
        'update_catalog_product', 'update_catalog_product_v3', 'update_catalog_product_v4', 'update_catalog_product_v5',
        'create_client_product_master', 'create_client_product_master_v2', 'update_client_product_master',
        'create_operation_order', 'create_operation_order_v2', 'create_operation_order_v3', 'create_operation_order_v4',
        'update_operation_order_v2', 'record_treatment_batch_v1', 'replace_client_product_controls'
      ])
  loop
    execute 'drop function ' || r.signature;
  end loop;
end $$;

notify pgrst, 'reload schema';
