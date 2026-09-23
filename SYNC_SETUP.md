# Setting up sign-in and sync

GRASP syncs through a Supabase project of your own. You'll need two free accounts: Supabase, and Google Cloud (Google Cloud is only for "Continue with Google"). Setup takes about 15 minutes. Until it's done, GRASP runs exactly as before, local-only.

## 1. Create the Supabase project

1. Sign in at [supabase.com](https://supabase.com) and click **New project**.
2. Name it `grasp`, pick the region nearest you, and set a database password. You won't need the password again for GRASP.
3. Once the project is ready, open **SQL Editor → New query**.
4. Paste in the whole of [`supabase/schema.sql`](supabase/schema.sql) and click **Run**.

   That creates the one table GRASP syncs through. It's locked down so each account can only ever see its own rows.

## 2. Tell Supabase where sign-in returns to

1. Go to **Authentication → URL Configuration**.
2. Under **Redirect URLs**, add `grasp://auth-callback`.

## 3. Email sign-in

Email is on by default. Optionally, go to **Authentication → Sign In / Providers → Email** and turn off **Confirm email**. New accounts can then sign in straight away instead of clicking a link first.

Supabase's built-in email sender allows only a few emails an hour. That's plenty for your own account, but it's why a sign-in link can occasionally be slow.

## 4. Google sign-in

1. Open the [Google Cloud Console](https://console.cloud.google.com) and create a project named `GRASP`.
2. Go to **APIs & Services → OAuth consent screen**.
   1. Choose **External**.
   2. Set the app name to GRASP, and use your email for both support and developer contact.
   3. Under **Test users**, add your own Google account.
3. Go to **APIs & Services → Credentials → Create credentials → OAuth client ID**.
   1. Set **Application type** to **Web application**.
   2. Under **Authorized redirect URIs**, add `https://<your-project-ref>.supabase.co/auth/v1/callback`.

      The project ref is the part before `.supabase.co` in your project URL. Supabase also shows this exact callback URL on its Google provider page.
   3. Click **Create**, then copy the **Client ID** and **Client secret**.
4. Back in Supabase, go to **Authentication → Sign In / Providers → Google**.
   1. Turn it on.
   2. Paste in the Client ID and secret, then **Save**.

## 5. Connect GRASP to the project

1. In Supabase, open **Project Settings → API** (called **Data API** / **API Keys** on newer dashboards).
2. Copy the **Project URL** and the **anon public** key. Both are safe to ship inside the app; row-level security is what protects your data.
3. Put them in `Info.plist`:

   ```xml
   <key>GRASPSupabaseURL</key>
   <string>https://<your-project-ref>.supabase.co</string>
   <key>GRASPSupabaseAnonKey</key>
   <string>eyJ...</string>
   ```

4. Rebuild with `./build.sh` and copy the app into `/Applications`. Or send the two values to Claude and it'll do this step.

## Using it

- **First device:** sign in from **Settings → Account & Sync** on your existing profile. Its whole library is uploaded to your account.

  You can also sign in on the profile screen and choose **Use a profile on this Mac**.
- **Another device:** sign in on the profile screen and choose **Download my library**. A new profile fills with everything from your account.
- **When it syncs:**
  - when a profile opens
  - a few seconds after you change something
  - every couple of minutes while GRASP is open
  - whenever you press **Sync Now** in Settings
- **What syncs:** courses, decks, cards, study progress and reviews, tests, calendar exams, note text and overviews.

  Original files (PDFs, slides, images) stay where they are. A second Mac needs its own copy of your notes folder to import new notes, but it has everything already imported.
- **Signing out** keeps the library on that device as a local profile. It just stops syncing.

## Windows and phones

The Mac app is the only client so far. The server side is general on purpose: every synced row sits in one table as plain JSON under your account. A future web app for Windows and phones, or a native iPhone app, signs into the same account and reads and writes the same rows. The only difference is which device writes them.
