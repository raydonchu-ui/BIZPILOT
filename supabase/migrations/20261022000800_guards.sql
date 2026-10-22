-- Additional integrity guards: units and base units that are referenced by
-- historical transactions cannot be redefined (history keeps its own copy, but
-- changing the definition would make future records inconsistent with the past).

create or replace function app.product_units_history_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.factor is distinct from old.factor or lower(new.name) is distinct from lower(old.name))
     and (exists (select 1 from public.sale_lines where unit_id = old.id)
          or exists (select 1 from public.purchase_lines where unit_id = old.id)) then
    perform app.raise('unit_in_use');
  end if;
  if new.product_id is distinct from old.product_id or new.business_id is distinct from old.business_id then
    perform app.raise('protected_field');
  end if;
  return new;
end $$;

create trigger product_units_history before update on public.product_units
  for each row execute function app.product_units_history_guard();

create or replace function app.products_base_unit_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.base_unit is distinct from old.base_unit
     and exists (select 1 from public.stock_movements where product_id = old.id) then
    perform app.raise('base_unit_locked');
  end if;
  if new.allow_fraction is distinct from old.allow_fraction and not new.allow_fraction
     and old.qty_on_hand <> trunc(old.qty_on_hand) then
    perform app.raise('fractional_quantity_not_allowed');
  end if;
  return new;
end $$;

create trigger products_base_unit before update on public.products
  for each row execute function app.products_base_unit_guard();

-- Guarantee only one default purchase / sale unit per product.
create unique index product_units_default_purchase on public.product_units (product_id) where is_default_purchase and active;
create unique index product_units_default_sale on public.product_units (product_id) where is_default_sale and active;

grant execute on function app.product_units_history_guard() to authenticated;
grant execute on function app.products_base_unit_guard() to authenticated;
