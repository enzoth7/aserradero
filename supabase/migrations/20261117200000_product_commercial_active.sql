-- Estado Activo / Inactivo del producto en el catálogo (distinto de stock_active, que lo oculta del catálogo).
-- Todos los productos existentes quedan inactivos.
alter table public.products
  add column if not exists commercial_active boolean not null default false;

comment on column public.products.commercial_active is 'Estado comercial del producto: true = Activo, false = Inactivo.';
