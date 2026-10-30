/// <reference path="../pb_data/types.d.ts" />
// Smart Content Creator production AI gateway: real upstream calls only.
// Environment: SCC_AI_API_KEY, SCC_AI_MODEL, optional SCC_AI_API_URL,
// SCC_AI_DAILY_LIMIT. No API credentials or demo responses are in this file.

routerAdd("POST", "/api/scc/ai/text", (e) => {
  const info = e.requestInfo();
  const user = info.auth;
  if (!user || !user.id) {
    return e.json(401, { error: "authentication_required" });
  }

  const input = info.body || {};
  const mode = String(input.mode || "chat");
  const modes = ["chat", "description", "hashtags", "ad", "script", "plan"];
  if (modes.indexOf(mode) === -1) {
    return e.json(400, { error: "unsupported_mode" });
  }
  const prompt = typeof input.prompt === "string" ? input.prompt.trim() : "";
  if (!prompt || prompt.length > 6000) {
    return e.json(400, { error: "invalid_prompt", maxLength: 6000 });
  }

  const key = $os.getenv("SCC_AI_API_KEY");
  const model = $os.getenv("SCC_AI_MODEL");
  const url = $os.getenv("SCC_AI_API_URL") ||
    "https://api.openai.com/v1/chat/completions";
  if (!key || !model) {
    return e.json(503, { error: "ai_provider_not_configured" });
  }
  if (!/^https:\/\//.test(url) || /[?#@]/.test(url)) {
    return e.json(503, { error: "ai_provider_url_invalid" });
  }

  const parsedLimit = parseInt($os.getenv("SCC_AI_DAILY_LIMIT") || "8", 10);
  const dailyLimit = Number.isFinite(parsedLimit)
    ? Math.max(1, Math.min(100, parsedLimit)) : 8;

  const since = new Date().toISOString().slice(0, 10) + " 00:00:00.000Z";
  const activeSince = new Date(Date.now() - 90000).toISOString()
    .replace("T", " ");
  let jobId = "";
  let limited = false;

  // Serialize usage reservation to avoid arbitrary parallel provider spend.
  try {
    e.app.runInTransaction((tx) => {
      // Hard global daily budget for the private no-login trial, including failures.
      // Reserved in the same transaction as per-user/concurrent limits.
      if (tx.findRecordsByFilter('ai_jobs', 'created >= {:since}', '', 50, 0,
          {since: since}).length >= 50) {
        limited = true;
        return;
      }
      const recent = tx.findRecordsByFilter(
        "ai_jobs",
        "owner = {:owner} && created >= {:since}",
        "-created", dailyLimit + 1, 0,
        { owner: user.id, since: since }
      );
      if (recent.length >= dailyLimit) {
        limited = true;
        return;
      }
      const active = tx.findRecordsByFilter(
        "ai_jobs",
        "owner = {:owner} && created >= {:since} && (state = 'queued' || state = 'running')",
        "-created", 1, 0,
        { owner: user.id, since: activeSince }
      );
      if (active.length > 0) {
        limited = true;
        return;
      }

      const record = new Record(tx.findCollectionByNameOrId("ai_jobs"));
      record.set("owner", user.id);
      record.set("job_type", mode);
      record.set("state", "running");
      record.set("request_id", "ai-" + Date.now().toString(36));
      tx.save(record);
      jobId = record.id;
    });
  } catch (_) {
    return e.json(503, { error: "ai_reservation_unavailable" });
  }
  if (limited) {
    return e.json(429, { error: "ai_quota_or_concurrent_request_limit" });
  }
  if (!jobId) {
    return e.json(503, { error: "ai_reservation_unavailable" });
  }

  const directions = {
    chat: "أجب بدقة وبالعربية ما لم يطلب المستخدم لغة أخرى.",
    description: "اكتب وصفًا تسويقيًا للمنتج مبنيًا فقط على المعلومات المتاحة، دون اختراع مواصفات أو سعر.",
    hashtags: "اقترح وسومًا عربية مناسبة للمحتوى، دون ادعاءات غير مثبتة.",
    ad: "اكتب نص إعلان عربي موجز مع دعوة لاتخاذ إجراء، باستخدام الحقائق المتاحة فقط.",
    script: "اكتب سيناريو فيديو قصيرًا دون اختراع مواصفات أو نتائج.",
    plan: "اكتب خطة محتوى واقعية دون افتراض بيانات أداء غير مقدمة."
  };
  const system = "أنت مساعد كتابة تجاري داخل تطبيق Smart Content Creator. " +
    "لا تختلق حقائق أو أسعارًا أو نتائج أو مواصفات أو مبيعات. " +
    "لا تتظاهر بالنشر أو الدفع أو إنشاء طلب. " + directions[mode];

  const payload = {
    model: model,
    messages: [
      { role: "system", content: system },
      { role: "user", content: prompt }
    ],
    max_completion_tokens: 1000
  };
  // Luna supports none: reserve the bounded budget for visible short-form output.
  // Other configured models keep their default reasoning behavior.
  if (model === "gpt-6-luna" || model.indexOf("gpt-6-luna-") === 0) {
    payload.reasoning_effort = "none";
  }

  let resultText = "";
  let failed = false;
  try {
    const response = $http.send({
      method: "POST",
      url: url,
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + key
      },
      timeout: 30,
      body: JSON.stringify(payload)
    });
    if (response.statusCode < 200 || response.statusCode >= 300) {
      failed = true;
    } else {
      const data = response.json || {};
      const choice = data.choices && data.choices.length
        ? data.choices[0] : null;
      const output = choice && choice.message
        ? choice.message.content : null;
      if (typeof output === "string") {
        resultText = output.trim().slice(0, 30000);
      }
      if (!resultText) failed = true;
    }
  } catch (_) {
    failed = true;
  }

  try {
    const job = e.app.findRecordById("ai_jobs", jobId);
    job.set("state", failed ? "failed" : "completed");
    if (!failed) job.set("result_text", resultText);
    e.app.save(job);
  } catch (_) {
    return e.json(503, { error: "ai_result_persistence_unavailable" });
  }

  if (failed) {
    // Never expose provider responses or key material to clients/logs.
    return e.json(502, { error: "ai_provider_request_failed" });
  }

  return e.json(200, {
    jobId: jobId,
    mode: mode,
    text: resultText
  });
}, $apis.requireAuth("users"));

