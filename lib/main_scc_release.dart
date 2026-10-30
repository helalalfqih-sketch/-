import 'package:flutter/material.dart';

import 'scc_pocketbase_app.dart';
import 'services/pocketbase/scc_pocketbase_client.dart';

/// Production Android entrypoint. Intentionally does not import/initialize
/// Firebase, Firestore, mock AI, or the legacy GetX dependency graph.
///
/// Build with:
/// flutter build appbundle --release -t lib/main_scc_release.dart
///   --dart-define=SCC_POCKETBASE_URL=https://creator-api.indexesstore.com
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  const backend = SccPocketBaseClient.configuredUrl;
  if (backend != 'https://creator-api.indexesstore.com') {
    throw StateError(
      'A trusted Smart Content Creator HTTPS production API is required.',
    );
  }

  runApp(const SccPocketBaseApp());
}
