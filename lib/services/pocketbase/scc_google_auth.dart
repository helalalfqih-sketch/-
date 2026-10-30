import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:url_launcher/url_launcher.dart';

import 'scc_pocketbase_client.dart';

/// System-browser OAuth with PKCE. No Google password or client secret in-app.
/// Does not depend on a background realtime connection on Android 15+.
class SccGoogleAuth {
  StreamSubscription<Uri>? _subscription;
  Completer<Uri>? _callback;
  bool _busy = false;
  int _generation = 0;

  Future<SccUserSession> signIn(SccPocketBaseClient client) async {
    if (_busy) throw StateError('Google login already pending');
    _busy = true;
    final generation = _generation;
    try {
    final request = await client.beginGoogleSignIn().timeout(const Duration(seconds: 30));
    if (generation != _generation) {
      request.cancel();
      throw const SccGoogleAuthCancelled();
    }
    final callback = Completer<Uri>();
    _callback = callback;
    // Register and attach an error handler before opening the browser.
    final result = callback.future.timeout(const Duration(minutes: 10));
    final outcome = result.then<SccUserSession>(
      (uri) => client.finishGoogleSignIn(request, uri),
    );
    // Avoid an unhandled future if browser launch itself fails.
    unawaited(outcome.then<void>((_) {}, onError: (Object _) {}));
    try {
      _subscription = AppLinks().uriLinkStream.listen((uri) {
        if (SccGoogleAuthRequest.isCallback(uri) && !callback.isCompleted) {
          callback.complete(uri);
        }
      }, onError: (Object error) {
        if (!callback.isCompleted) callback.completeError(error);
      });
      final opened = await launchUrl(
        request.authorizationUrl,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw StateError('Could not open Google sign-in');
      return await outcome;
    } finally {
      request.cancel();
      await _subscription?.cancel();
      _subscription = null;
      if (!callback.isCompleted) callback.completeError(const SccGoogleAuthCancelled());
      _callback = null;
    }
    } finally {
      _busy = false;
    }
  }

  void cancel() {
    _generation++;
    final callback = _callback;
    if (callback != null && !callback.isCompleted) {
      callback.completeError(const SccGoogleAuthCancelled());
    }
  }
}

class SccGoogleAuthCancelled implements Exception {
  const SccGoogleAuthCancelled();
}
