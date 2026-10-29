import 'dart:convert';

import 'package:http/http.dart' as http;

/// Preview-only client for an isolated, HTTPS-authenticated VPS backend.
///
/// Disabled by default. Does NOT replace Firebase Authentication, and cannot
/// connect directly to the VPS loopback listener from an Android device.
///
/// This client keeps a temporary preview session in memory only. Production
/// credentials and refresh-token storage require a separate security review.
class VpsAuthPreviewClient {
  static const String configuredUrl =
      String.fromEnvironment('SCC_VPS_AUTH_PREVIEW_URL', defaultValue: '');

  VpsAuthPreviewClient({
    String baseUrl = configuredUrl,
    http.Client? client,
  })  : _baseUrl = _validateBaseUrl(baseUrl),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final Uri? _baseUrl;
  final http.Client _client;
  final bool _ownsClient;
  String? _sessionToken;

  bool get isConfigured => _baseUrl != null;
  bool get hasSession => _sessionToken != null;

  static Uri? _validateBaseUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError.value(raw, 'baseUrl', 'HTTPS endpoint required');
    }
    return uri;
  }

  Uri _route(String path) {
    final base = _baseUrl;
    if (base == null) throw StateError('VPS preview is disabled');
    return base.resolve(path);
  }

  Map<String, String> _headers({bool authorized = false}) {
    final headers = <String, String>{'Accept': 'application/json'};
    if (authorized) {
      final token = _sessionToken;
      if (token == null) throw StateError('No preview session');
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Future<bool> login({
    required String email,
    required String password,
  }) async {
    if (!isConfigured) return false;
    _sessionToken = null;
    try {
      final response = await _client
          .post(
            _route('/v1/auth/login'),
            headers: {..._headers(), 'Content-Type': 'application/json'},
            body: jsonEncode({'email': email, 'password': password}),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return false;
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return false;
      final token = body['access_token'];
      if (token is! String || token.length < 20) return false;
      _sessionToken = token;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> getCurrentUser() async {
    if (!hasSession) return null;
    try {
      final response = await _client
          .get(_route('/v1/auth/me'), headers: _headers(authorized: true))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 401) {
        _sessionToken = null;
        return null;
      }
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return null;
      final user = body['user'];
      return user is Map<String, dynamic> ? user : null;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> listProducts() async {
    if (!hasSession) throw StateError('No preview session');
    final response = await _client
        .get(_route('/v1/products'), headers: _headers(authorized: true))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode == 401) {
      _sessionToken = null;
      throw StateError('Preview session expired');
    }
    if (response.statusCode != 200) throw StateError('Preview API failed');
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic> || body['items'] is! List) {
      throw const FormatException('Invalid preview response');
    }
    return (body['items'] as List).cast<Map<String, dynamic>>();
  }

  /// Drafts only. Owner and role are ALWAYS assigned by the server.
  Future<Map<String, dynamic>> createDraft({
    required String title,
    required String priceDecimal,
    String currency = 'YER',
    int quantity = 0,
  }) async {
    if (!hasSession) throw StateError('No preview session');
    final response = await _client
        .post(
          _route('/v1/products'),
          headers: {
            ..._headers(authorized: true),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'title': title,
            'price_decimal': priceDecimal,
            'currency': currency,
            'quantity': quantity,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 201) {
      throw StateError('Preview draft was not created');
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic> ||
        body['product'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid preview response');
    }
    return body['product'] as Map<String, dynamic>;
  }

  Future<void> logout() async {
    final token = _sessionToken;
    _sessionToken = null;
    if (token == null || !isConfigured) return;
    try {
      await _client
          .post(
            _route('/v1/auth/logout'),
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Local session must still be forgotten.
    }
  }

  void dispose() {
    _sessionToken = null;
    if (_ownsClient) _client.close();
  }
}
