-- Package / Tier First Pricing Function
create or replace function app._time_amount(g games, p_minutes int, p_first boolean default false) returns numeric
language plpgsql immutable as $$
declare
  v_tier_price text;
begin
  -- Check if exact pricing tier package exists for p_minutes
  if g.pricing_tiers is not null and g.pricing_tiers ? p_minutes::text then
    v_tier_price := g.pricing_tiers ->> p_minutes::text;
    if v_tier_price is not null and v_tier_price <> '' then
      return round(v_tier_price::numeric, 2);
    end if;
  end if;

  -- Fallback pricing unit calculation
  return round(case g.pricing_unit
    when 'per_minute'     then g.price * p_minutes
    when 'per_15_minutes' then g.price * ceil(p_minutes / 15.0)
    when 'per_30_minutes' then g.price * ceil(p_minutes / 30.0)
    when 'per_hour'       then g.price * ceil(p_minutes / 60.0)
    when 'fixed_price'    then case when p_first then g.price else 0 end
    else g.price * ceil(p_minutes / 60.0) end, 2);
end $$;
