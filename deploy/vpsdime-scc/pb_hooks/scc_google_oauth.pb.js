// HTTPS OAuth callback bridge. Client verifies one-use state and exchanges with PKCE.
// No client secret, access token or arbitrary redirect destination is accepted here.
routerAdd("GET", "/api/scc/oauth/google/callback", (e) => {
  e.response.header().set("Cache-Control", "no-store");
  e.response.header().set("Referrer-Policy", "no-referrer");
  e.response.header().set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'; base-uri 'none'");
  const q = JSON.parse(toString(e.request.url.query())) || {};
  const single = (key) => Array.isArray(q[key]) && q[key].length === 1 ? q[key][0] : "";
  const state = single("state");
  const code = single("code");
  const error = single("error");
  if (!/^[A-Za-z0-9_-]{43}$/.test(state) ||
      (error ? (!!code || !/^[a-z_]{1,80}$/.test(error)) : (!code || code.length > 8192)) ||
      (q.code && q.code.length !== 1) || (q.error && q.error.length !== 1)) {
    return e.html(400, '<html lang="ar" dir="rtl"><meta charset="utf-8"><p>تعذر إكمال الدخول. ارجع إلى التطبيق وحاول مجددًا.</p></html>');
  }
  const uri = "com.indexes.scc://oauth/google?state=" + encodeURIComponent(state) +
    (error ? "&error=" + encodeURIComponent(error) : "&code=" + encodeURIComponent(code));
  const escaped = uri.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return e.html(200, '<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>صانع المحتوى</title><h1>العودة إلى صانع المحتوى</h1><p><a href="' + escaped + '">اضغط هنا لإكمال الدخول في التطبيق</a></p><p>إذا أُغلق التطبيق، افتحه وابدأ تسجيل الدخول مجددًا.</p></html>');
});
