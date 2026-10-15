-- Allow venue customers to read active sessions of their venue so they can see post status, game images, and timers on the posts screen.
drop policy if exists sessions_staff_read on sessions;
drop policy if exists sessions_own_read on sessions;

create policy sessions_venue_member_read on sessions for select using (
  app.is_staff(venue_id)
  or exists (
    select 1 from customers c
    where c.venue_id = sessions.venue_id
    and c.user_id = auth.uid()
  )
);
