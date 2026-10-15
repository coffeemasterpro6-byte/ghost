-- Add pricing_tiers jsonb column to games table if not exists
alter table games add column if not exists pricing_tiers jsonb default '{}'::jsonb;
