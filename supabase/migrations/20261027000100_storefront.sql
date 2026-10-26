-- Storefront upgrade: each product card carries a real stock status (in / low / out) computed from
-- the stock on hand and the product's minimum-stock setting, so the storefront can show
-- "In Stock", "Low Stock" and "Out of Stock" from recorded data only.
-- Storefront customers are read-only: store editing stays behind store_save (store.manage).

create or replace function app.product_card(p_listing uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'brand', p.brand,
    'image', p.online_images[1], 'unit', p.base_unit,
    'price', o.min_price, 'max_price', o.max_price, 'compare_at_price',
      case when p.compare_at_price > o.min_price then p.compare_at_price end,
    'available', least(o.available, 99), 'options', o.n,
    'stock', case when coalesce(o.available, 0) <= 0 then 'out'
                  when coalesce(p.min_stock, 0) > 0 and o.available <= p.min_stock then 'low'
                  else 'in' end,
    'category', c.name, 'subcategory', p.subcategory,
    'condition', p.condition, 'sold', p.single_item and coalesce(o.available, 0) <= 0,
    'rating_avg', r.avg, 'rating_count', coalesce(r.n, 0),
    'store', jsonb_build_object('slug', s.slug, 'name', s.name, 'city', s.city, 'verified', s.verification = 'verified',
                                'logo_path', s.logo_path))
  from public.products p
  join public.stores s on s.business_id = p.business_id
  left join public.categories c on c.id = p.category_id
  cross join lateral (select min(x.price) min_price, max(x.price) max_price, sum(x.available) available, count(*) n
                        from app.listing_options(p.id) x) o
  left join lateral (select round(avg(rating), 1) avg, count(*) n from public.market_reviews
                      where listing_id = p.id and status = 'visible') r on true
  where p.id = p_listing
$$;
