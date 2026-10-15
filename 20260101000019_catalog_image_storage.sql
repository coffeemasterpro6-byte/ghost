insert into storage.buckets(
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'venue-catalog-images',
  'venue-catalog-images',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create policy venue_catalog_images_public_read
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'venue-catalog-images');

create policy venue_catalog_images_staff_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'venue-catalog-images'
    and case
      when array_length(storage.foldername(name), 1) = 1
        and (storage.foldername(name))[1] ~*
          '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then app.is_admin((storage.foldername(name))[1]::uuid)
      else false
    end
  );
