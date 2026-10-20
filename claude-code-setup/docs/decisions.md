# Decisions log

Short record of choices that shape the design. Feeds the README "scope decisions" section.

1. **Onboarding runs through `complete_onboarding`, a security definer function**, called as the
   signed-in user. The alternative was the service role key in a server action. This keeps the
   privileged key out of the sign-up path and keeps validation (reserved handles, 18+, US address)
   in the database.
2. **One main account per user**, enforced by a unique partial index, because top-up and transfers assume it.
3. **Account numbers retry on collision** (up to 5 times) instead of failing sign-up.
4. **post_transfer re-reads limits after taking the row lock**, so a concurrent limit change cannot be missed.
5. **Daily limit is a rolling 24 hours**, not a calendar day.
6. **Sessions verified with getClaims()**, never getSession(), on the server.
7. **Next.js app lives in web/** beside supabase/ and tests/; Vercel root directory is web.
8. **Auth errors are deliberately vague** so the app never reveals whether an email is registered.
9. **No SSN collected, no FDIC claims**: onboarding collects name, date of birth and US address only.
