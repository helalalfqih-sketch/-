# Google sign-in setup (Android preview)

Status: code staged; not activated or verified against a live Google account.

1. In the owner's Google Cloud project, configure Google Auth Platform branding and audience. During testing, add the intended Google account as a test user.
2. Create a **Web application** OAuth client. Register this exact authorized redirect URI:
   `https://creator-api.indexesstore.com/api/scc/oauth/google/callback`
3. Through an authorized private PocketBase administration session, enable the Google provider on the **users** auth collection using that client ID and secret. Keep secrets server-side, preserve other providers and keep `users.createRule` locked. Never configure `_superusers` for app sign-in.
4. Deploy `pb_hooks/scc_google_oauth.pb.js` into the existing root-owned hook mount and restart PocketBase using the existing production deployment procedure. Do not expose the admin API or port 8090.
5. Build the Android preview from this commit with `SCC_POCKETBASE_URL=https://creator-api.indexesstore.com`, install, choose Google, then tap the callback page's return-to-app link. Sign-in can create a normal user automatically. Confirm private product isolation and logout before distributing.

The app uses the system browser, a random one-use state, SHA-256 PKCE and a fixed Android callback URI. Only the authorization code and state pass through the callback page; provider credentials stay on the server. Transactions expire after ten minutes and are not restored after process death; restart sign-in if Android closes the app. iOS/web are not configured by this Android change. Avoid logging OAuth callback query strings in proxy/access logs.

Do not claim Google login works until the provider is configured and a real account completes the end-to-end flow. Existing password login remains an optional secondary path during migration.
