/// <reference path="../pb_data/types.d.ts" />
// Smart Content Creator schema v1 — PocketBase 0.40.6.
// Fail closed: public user signup stays disabled until email + anti-abuse are set.
// No seed accounts, credentials, subscriptions, or product data are created.
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  const usersId = users.id;
  users.listRule = "@request.auth.id != '' && id = @request.auth.id";
  users.viewRule = "@request.auth.id != '' && id = @request.auth.id";
  users.createRule = null;
  users.updateRule = "@request.auth.id != '' && id = @request.auth.id && @request.body.verified:isset = false";
  users.deleteRule = "@request.auth.id != '' && id = @request.auth.id";
  app.save(users);

  const authGuard = "@request.auth.id != ''";
  const ownerRule = authGuard + " && owner = @request.auth.id";
  const createOwn = authGuard + " && @request.body.owner = @request.auth.id";
  const updateOwn = ownerRule + " && @request.body.owner:changed = false";
  const owner = () => ({
    name: "owner", type: "relation", collectionId: usersId,
    required: true, maxSelect: 1, cascadeDelete: true
  });
  const dates = () => [
    { name: "created", type: "autodate", onCreate: true, onUpdate: false },
    { name: "updated", type: "autodate", onCreate: true, onUpdate: true }
  ];
  const store = (data) => app.save(new Collection(data));

  store({
    type: "base", name: "products",
    listRule: ownerRule, viewRule: ownerRule,
    createRule: createOwn, updateRule: updateOwn, deleteRule: ownerRule,
    fields: [
      owner(),
      { name: "title", type: "text", required: true, max: 240 },
      { name: "sku", type: "text", max: 120 },
      { name: "description", type: "text", max: 20000 },
      // Store monetary values as integer minor units; never use floating point for money.
      { name: "price_minor", type: "number", min: 0, onlyInt: true },
      { name: "currency", type: "select", values: ["YER", "USD", "SAR"], maxSelect: 1 },
      { name: "quantity", type: "number", min: 0, onlyInt: true },
      { name: "status", type: "select", values: ["draft", "active", "archived"], maxSelect: 1 },
      ...dates()
    ],
    indexes: ["CREATE INDEX idx_scc_products_owner ON products (owner)"]
  });

  store({
    type: "base", name: "media_assets",
    listRule: ownerRule, viewRule: ownerRule,
    createRule: createOwn, updateRule: updateOwn, deleteRule: ownerRule,
    fields: [
      owner(),
      { name: "file", type: "file", required: true, protected: true,
        maxSelect: 1, maxSize: 26214400,
        mimeTypes: ["image/jpeg", "image/png", "image/webp", "video/mp4"] },
      { name: "label", type: "text", max: 240 },
      ...dates()
    ],
    indexes: ["CREATE INDEX idx_scc_media_owner ON media_assets (owner)"]
  });

  store({
    type: "base", name: "content_items",
    listRule: ownerRule, viewRule: ownerRule,
    createRule: createOwn, updateRule: updateOwn, deleteRule: ownerRule,
    fields: [
      owner(),
      { name: "title", type: "text", required: true, max: 240 },
      { name: "body", type: "text", max: 30000 },
      { name: "format", type: "select", values: ["post", "reel", "story", "ad"], maxSelect: 1 },
      { name: "status", type: "select", values: ["draft", "review", "ready", "published"], maxSelect: 1 },
      ...dates()
    ],
    indexes: ["CREATE INDEX idx_scc_content_owner ON content_items (owner)"]
  });

  // Client cannot assign roles, alter plans, mark AI jobs completed, or forge audit events.
  store({
    type: "base", name: "user_roles",
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null,
    fields: [
      { name: "user", type: "relation", collectionId: usersId, required: true, maxSelect: 1, cascadeDelete: true },
      { name: "role", type: "select", values: ["member", "editor", "admin"], maxSelect: 1 },
      ...dates()
    ],
    indexes: ["CREATE UNIQUE INDEX idx_scc_roles_user ON user_roles (user)"]
  });

  store({
    type: "base", name: "ai_jobs",
    listRule: ownerRule, viewRule: ownerRule,
    createRule: null, updateRule: null, deleteRule: null,
    fields: [
      owner(),
      { name: "job_type", type: "text", required: true, max: 120 },
      { name: "state", type: "select", values: ["queued", "running", "completed", "failed"], maxSelect: 1 },
      { name: "request_id", type: "text", max: 128 },
      { name: "result_text", type: "text", max: 30000 },
      ...dates()
    ],
    indexes: ["CREATE INDEX idx_scc_jobs_owner ON ai_jobs (owner)"]
  });

  store({
    type: "base", name: "subscriptions",
    listRule: ownerRule, viewRule: ownerRule,
    createRule: null, updateRule: null, deleteRule: null,
    fields: [
      owner(),
      { name: "plan", type: "text", max: 100 },
      { name: "state", type: "select", values: ["trial", "active", "expired", "cancelled"], maxSelect: 1 },
      { name: "expires_at", type: "date" },
      ...dates()
    ],
    indexes: ["CREATE INDEX idx_scc_subscriptions_owner ON subscriptions (owner)"]
  });

  store({
    type: "base", name: "audit_events",
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null,
    fields: [
      { name: "actor", type: "relation", collectionId: usersId, maxSelect: 1 },
      { name: "action", type: "text", required: true, max: 120 },
      { name: "subject", type: "text", max: 200 },
      { name: "context", type: "json", maxSize: 4096 },
      { name: "created", type: "autodate", onCreate: true }
    ]
  });
}, (app) => {
  // Reverse dependency order. Do not run down on production containing user data.
  for (const name of ["audit_events", "subscriptions", "ai_jobs", "user_roles",
                      "content_items", "media_assets", "products"]) {
    const collection = app.findCollectionByNameOrId(name);
    app.delete(collection);
  }
  // Do not revert 'users' rules automatically; fail closed on rollback.
});
