# Valentino The Barber

Website and booking system for Valentino The Barbershop, Franklin D. Rooseveltweg 307N (Dupont), Curaçao. Replaces Fresha.

Live site: https://a3dprintingcw-cyber.github.io/Valentino-web/
Admin: https://a3dprintingcw-cyber.github.io/Valentino-web/admin.html

## What's in here

| File | What it does |
| --- | --- |
| `index.html` | Public site: services, online booking, house call request, hours, location |
| `admin.html` | Valentino's page: today's agenda, mark done or no-show, cancel, add walk-ins, block time, edit services, prices and hours |
| `config.js` | Supabase keys and phone numbers |
| `supabase/schema.sql` | Database tables, security rules and booking functions |
| `supabase/functions/notify-booking` | Emails Valentino on every new or cancelled online booking |

How booking works: the customer picks services, a day and a free time, then enters name and phone. The database checks hours, blocks and other bookings, and refuses double bookings even if two people tap at the same moment. The customer gets a link to cancel up to 1 hour before. Payment happens in the shop.

Until `config.js` has the Supabase keys, the booking button sends people to `fallbackUrl` (the old Fresha link).

## Setup (one time, about 20 minutes)

### 1. Supabase project
1. Create a free account at supabase.com and a new project (region: East US is closest).
2. Open **SQL Editor > New query**, paste all of `supabase/schema.sql`, tap **Run**.
3. **Project Settings > API**: copy the **Project URL** and the **anon public** key into `config.js`.

### 2. Valentino's login
1. **Authentication > Users > Add user > Create new user**: his email and a password, tick "Auto confirm".
2. **Authentication > Sign In / Providers**: turn **off** "Allow new users to sign up".
3. SQL Editor, run (with his email):
   ```sql
   insert into public.admins (user_id)
   select id from auth.users where email = 'HIS_EMAIL_HERE';
   ```

### 3. Email per booking
1. Create a free account at resend.com and an API key. To send from your own domain, verify it in Resend; otherwise the test sender only delivers to the Resend account's own email, so sign up with Valentino's email.
2. Deploy the function (needs the Supabase CLI):
   ```sh
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   supabase functions deploy notify-booking --no-verify-jwt
   supabase secrets set RESEND_API_KEY=re_xxx NOTIFY_EMAIL=valentino@example.com WEBHOOK_SECRET=some-long-random-text SITE_URL=https://a3dprintingcw-cyber.github.io/Valentino-web
   ```
3. **Database > Webhooks > Create**: table `bookings`, events **Insert** and **Update**, type **Supabase Edge Functions**, function `notify-booking`, add header `x-webhook-secret` with the same value as `WEBHOOK_SECRET`.

### 4. Go live
Commit `config.js` with the keys and push. The anon key is safe to publish: customers can only use the booking functions, and only Valentino's account can read bookings.

## Moving off Fresha
1. Copy his upcoming Fresha appointments in with **+ Booking** on the admin page.
2. Change the Instagram bio link to the new site.
3. Turn off online booking in Fresha.
