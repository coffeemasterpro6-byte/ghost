-- 031 ADD YOUTUBE URL TO POSTS
-- Allows venue owners/managers to set an optional YouTube trailer URL for gaming posts.

alter table posts add column if not exists youtube_url text;
