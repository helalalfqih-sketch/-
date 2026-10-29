import 'dart:convert';

import 'package:http/http.dart' as http;

/// Opt-in health probe for the future VPS backend.
///
/// This does NOT replace Firebase Auth or existing application repositories.
/// It is intentionally disabled until a separate, authenticated HTTPS endpoint
/// is deployed and SCC_VPS_API_URL is explicitly set at build time.
class VpsStagingApi {
  static const String configuredUrl =
      String.fromEnvironment('SCC_VPS_API_URL', defaultValue: '');

  VpsStagingApi({String baseUrl = configuredUrl, http.Client? client})
      : _baseUrl = _validatedBaseUrl(baseUrl),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final Uri? _baseUrl;
  final http.Client _client;
  final bool _ownsClient;

  bool get isConfigured => _baseUrl != null;

  static Uri? _validatedBaseUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError.value(
        raw,
        'baseUrl',
        'An HTTPS URL without credentials, query, or fragment is required.',
      );
    }
    return uri;
  }

  /// Returns false when disabled, unreachable, or the backend is unhealthy.
  /// No access token or user information is sent.
  Future<bool> checkHealth() async {
    final baseUrl = _baseUrl;
    if (baseUrl == null) return false;
    try {
      final response = await _client
          .get(baseUrl.resolve('/healthz'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return false;
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> && decoded['status'] == 'ok';
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
