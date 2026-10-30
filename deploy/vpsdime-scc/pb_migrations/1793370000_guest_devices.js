// Private device identities. No public CRUD API; tokens retain ordinary users scope.
migrate((app) => {
  app.save(new Collection({
    name: "scc_guest_devices", type: "base",
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null,
    fields: [
      {name: "secret_hash", type: "text", required: true, hidden: true, min: 64, max: 64},
      {name: "owner", type: "relation", collectionId: app.findCollectionByNameOrId("users").id, required: true, maxSelect: 1, cascadeDelete: false},
      {name: "disabled", type: "bool"},
      {name: "created", type: "autodate", onCreate: true, onUpdate: false}
    ],
    indexes: [
      "CREATE UNIQUE INDEX idx_scc_guest_secret ON scc_guest_devices (secret_hash)",
      "CREATE UNIQUE INDEX idx_scc_guest_owner ON scc_guest_devices (owner)"
    ]
  }));
}, (app) => {
  // Explicit rollback only; does not delete guest users or their private content.
  app.delete(app.findCollectionByNameOrId("scc_guest_devices"));
});
