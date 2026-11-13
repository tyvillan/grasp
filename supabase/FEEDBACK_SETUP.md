# Setting up feedback

People you show GRASP to can send feedback from inside the app (Settings > Send feedback, or Help > Send feedback on the Mac). It goes to your own Supabase project, and you read it in the dashboard. This is separate from sync: it needs no accounts, and it works for someone who has never signed in.

## What you run, in order

1. **Nothing is needed first.** The app already holds your project URL and public key (`GRASPSupabaseURL` and `GRASPSupabaseAnonKey` in `Info.plist`, from [SYNC_SETUP.md](../SYNC_SETUP.md)). If those are empty, feedback says it isn't set up.
2. In Supabase, open **SQL Editor -> New query**, paste the whole of [`feedback.sql`](feedback.sql), and click **Run**. It makes the table, its rules, the inbox view, the screenshot bucket and their policies. It is safe to run twice. You should see "Success. No rows returned".
3. Check it in two clicks:
   - **Table Editor** now lists `feedback`, with a shield showing row-level security is on.
   - **Storage** lists a private bucket, `feedback-screenshots`.
4. Open **SQL Editor** and save the three queries in [`feedback-queries.md`](feedback-queries.md).
5. Install a build of GRASP from the `feedback` branch, open Settings > Send feedback, send "test", and look for the row in the Table Editor. Delete the test row afterwards (click it, then the bin icon).

Do not run anything else. There is no key to rotate and nothing to change in `Info.plist`.

## Which role the app uses

The app sends feedback with only the **anon** (public) key, as a plain request, with no signed-in session. That means the `anon` role, whether or not the person has an account for sync. Sync is different: it signs in and uses the `authenticated` role. The policies allow both, but only `anon` is ever used, so nobody needs an account to send feedback.

The anon key is public by design (it ships in the app). What it can do is exactly what the policies allow:

| | Rows (`feedback`) | Pictures (`feedback-screenshots`) |
|---|---|---|
| Insert | yes, only the columns the app sets | yes, only a uuid-named .jpg, 600 KB at most |
| Select, update, delete | no | no |

`created_at` and `status` are filled by the server. The app cannot set them.

## Abuse and spam

Anyone who pulls the key out of the app can call the insert endpoint directly. They cannot read or change anything, but they could send junk. The limits:

- **In the app:** 5 sends a day per install, a 4000 character message, and a 500 KB picture. This keeps honest users from flooding you; it does not stop someone who skips the app.
- **In the database:** a message of 1 to 4000 characters, a type from a fixed list, a rating of 1 to 5, and fixed maximum lengths on every other column. An anonymous row cannot carry a name or an email. A flood guard allows at most 20 rows a day per install id and 100 rows an hour in total.
- **In storage:** one private bucket, JPEG only, 600 KB at most, and a name that must be a uuid plus `.jpg`.

What is left: a determined person can fill the 100 an hour cap and make real feedback wait, or upload up to 600 KB pictures that no row points to. Real feedback is not lost: the app keeps it and sends again later. If it ever happens, delete the rows, or turn the policy off in the dashboard (Authentication -> Policies) until it stops. The install id is random and can be changed by anyone, so it is a courtesy limit, not security.

## Cost and size on the free tier

At the time of writing the free plan includes about 500 MB of database, 1 GB of file storage and 5 GB of bandwidth a month. Check the current numbers on Supabase's pricing page.

- **Text:** one row is about 1 KB, so 500 MB holds hundreds of thousands. You will not get near it.
- **Screenshots:** at most 500 KB each, so 1 GB holds about 2,000. Delete old ones from the Storage browser when you have read them.
- **One catch:** free projects pause after a week with no activity. Sync usually keeps yours awake. If it pauses, feedback queues on each device and sends once you restore the project from the dashboard.
