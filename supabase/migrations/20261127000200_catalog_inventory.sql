-- لمسات | الكتالوج والمخزون والعملاء

create table public.products (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  sku             text not null,
  kind            text not null check (kind in ('item','service')),
  category        text not null default 'general' check (category in ('tire','tint','accessory','service','general')),
  name_ar         text not null,
  name_en         text,
  brand           text,
  unit            text not null default 'قطعة',
  whole_units_only boolean not null default true,
  track_stock     boolean not null default true,
  taxable         boolean not null default true,
  base_price_baisa bigint not null check (base_price_baisa >= 0),
  tire_width      int,
  tire_aspect     int,
  tire_rim        int,
  -- مفتاح بحث المقاس: 205/55R16 → 2055516
  tire_size_key   text generated always as (
    case when tire_width is not null and tire_aspect is not null and tire_rim is not null
         then tire_width::text || tire_aspect::text || tire_rim::text end) stored,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (organization_id, sku),
  unique (id, organization_id),
  check (kind = 'item' or track_stock = false)
);
create index products_org_name_idx on public.products (organization_id, name_ar);
create index products_tire_size_idx on public.products (organization_id, tire_size_key) where tire_size_key is not null;

create table public.product_barcodes (
  organization_id uuid not null,
  barcode         text not null,
  product_id      uuid not null,
  primary key (organization_id, barcode),
  foreign key (product_id, organization_id) references public.products(id, organization_id) on delete cascade
);

-- سعر خاص بالفرع يتقدّم على سعر المنشأة
create table public.branch_prices (
  branch_id       uuid not null,
  product_id      uuid not null,
  organization_id uuid not null,
  price_baisa     bigint not null check (price_baisa >= 0),
  updated_at      timestamptz not null default now(),
  primary key (branch_id, product_id),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id),
  foreign key (product_id, organization_id) references public.products(id, organization_id)
);

-- دفعات المخزون (FIFO). الرصيد = مجموع qty_on_hand، وكل تغيير له حركة في stock_movements.
create table public.inventory_lots (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  product_id      uuid not null,
  lot_code        text,
  dot_code        text,
  received_at     timestamptz not null default now(),
  unit_cost_baisa bigint not null check (unit_cost_baisa >= 0),
  qty_received    numeric(12,3) not null check (qty_received > 0),
  qty_on_hand     numeric(12,3) not null check (qty_on_hand >= 0),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id),
  foreign key (product_id, organization_id) references public.products(id, organization_id),
  check (qty_on_hand <= qty_received)
);
create index inventory_lots_fifo_idx on public.inventory_lots (branch_id, product_id, received_at, id) where qty_on_hand > 0;

create table public.stock_movements (
  id              bigint generated always as identity primary key,
  organization_id uuid not null,
  branch_id       uuid not null,
  product_id      uuid not null,
  lot_id          uuid not null references public.inventory_lots(id),
  movement_type   text not null check (movement_type in
    ('opening','purchase_receipt','sale','sale_return','void_reversal','adjustment','transfer_out','transfer_in')),
  qty_delta       numeric(12,3) not null check (qty_delta <> 0),
  unit_cost_baisa bigint not null,
  source_type     text,
  source_id       uuid,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id),
  foreign key (product_id, organization_id) references public.products(id, organization_id)
);
create index stock_movements_product_idx on public.stock_movements (branch_id, product_id, created_at);
create index stock_movements_source_idx on public.stock_movements (source_type, source_id);

create table public.customers (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  name            text not null,
  phone           text,
  preferred_lang  text not null default 'ar' check (preferred_lang in ('ar','en')),
  notes           text,
  created_at      timestamptz not null default now(),
  unique (id, organization_id)
);
create unique index customers_phone_uniq on public.customers (organization_id, phone) where phone is not null;

create table public.vehicles (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  customer_id     uuid,
  plate           text not null,
  make            text,
  model           text,
  created_at      timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (customer_id, organization_id) references public.customers(id, organization_id)
);
create index vehicles_plate_idx on public.vehicles (organization_id, plate);
