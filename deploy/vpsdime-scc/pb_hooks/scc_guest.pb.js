// Closed by default. Private trial: 10 device identities total, persistent across restarts.
// Device bearer secret is generated and saved in secure storage before the first request.
routerAdd("POST", "/api/scc/guest/session", (e) => {
  e.response.header().set("Cache-Control", "no-store");
  if ($os.getenv("SCC_GUEST_ENABLED") !== "1") {
    return e.json(503, {error: "guest_disabled"});
  }
  const secret = (e.requestInfo().body || {}).deviceSecret;
  if (typeof secret !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(secret)) {
    return e.json(400, {error: "invalid_device_secret"});
  }
  const hash = $security.sha256(secret);
  let user;
  let denied = 0;
  try {
    e.app.runInTransaction((tx) => {
      const matches = tx.findRecordsByFilter("scc_guest_devices", "secret_hash = {:hash}", "", 1, 0, {hash});
      if (matches.length) {
        if (matches[0].getBool("disabled")) { denied = 403; return; }
        user = tx.findRecordById("users", matches[0].getString("owner"));
        return;
      }
      // A hard lifetime cap protects billing even if callers rotate device secrets/IPs.
      if (tx.findRecordsByFilter("scc_guest_devices", "", "", 10, 0).length >= 10) {
        denied = 429; return;
      }
      user = new Record(tx.findCollectionByNameOrId("users"));
      user.set("email", "guest-" + $security.randomString(32).toLowerCase() + "@guest.invalid");
      user.set("password", $security.randomString(64));
      user.set("emailVisibility", false);
      tx.save(user);
      const device = new Record(tx.findCollectionByNameOrId("scc_guest_devices"));
      device.set("secret_hash", hash);
      device.set("owner", user.id);
      tx.save(device);
    });
    if (denied) return e.json(denied, {error: "guest_access_unavailable"});
    return e.json(200, {token: user.newAuthToken(), record: {
      id: user.id, email: "", collectionName: "users"
    }});
  } catch (_) {
    // Neither bearer secrets nor DB/provider diagnostics belong in client responses.
    return e.json(503, {error: "guest_session_unavailable"});
  }
});
