import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

/// Token storage is injectable to make authorization tests deterministic.
abstract class SccTokenStore {
  Future<String?> read();
  Future<void> write(String? token);
}

class SccSecureTokenStore implements SccTokenStore {
  SccSecureTokenStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'scc_pocketbase_user_token';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String? token) async {
    if (token == null) {
      await _storage.delete(key: _key);
    } else {
      await _storage.write(key: _key, value: token);
    }
  }
}

class SccApiException implements Exception {
  const SccApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'SccApiException($statusCode): $message';
}

class SccUserSession {
  const SccUserSession({required this.id, required this.email});

  final String id;
  final String email;

  factory SccUserSession.fromJson(Map<String, dynamic> source) =>
      SccUserSession(
        id: source['id'] as String,
        email: (source['email'] as String?) ?? '',
      );
}

class SccProduct {
  const SccProduct({
    required this.id,
    required this.owner,
    required this.title,
    required this.priceMinor,
    required this.currency,
    required this.status,
  });

  final String id;
  final String owner;
  final String title;
  final int priceMinor;
  final String currency;
  final String status;

  factory SccProduct.fromJson(Map<String, dynamic> source) => SccProduct(
        id: source['id'] as String,
        owner: source['owner'] as String,
        title: source['title'] as String,
        priceMinor: ((source['price_minor'] as num?) ?? 0).toInt(),
        currency: (source['currency'] as String?) ?? '',
        status: (source['status'] as String?) ?? '',
      );
}

/// An opt-in PocketBase client for Smart Content Creator.
/// Disabled until SCC_POCKETBASE_URL is supplied at build time.
/// Uses normal user accounts, never a PocketBase superuser credential.
class SccPocketBaseClient {
  SccPocketBaseClient({
    required String baseUrl,
    http.Client? httpClient,
    SccTokenStore? tokenStore,
  })  : _baseUrl = _validateBaseUrl(baseUrl),
        _http = httpClient ?? http.Client(),
        _store = tokenStore ?? SccSecureTokenStore();

  static const configuredUrl =
      String.fromEnvironment('SCC_POCKETBASE_URL', defaultValue: '');

  final Uri _baseUrl;
  final http.Client _http;
  final SccTokenStore _store;
  String? _currentUserId;

  static Uri _validateBaseUrl(String input) {
    final url = Uri.tryParse(input);
    final local = url?.host == 'localhost' || url?.host == '127.0.0.1';
    if (url == null ||
        url.host.isEmpty ||
        (url.scheme != 'https' && !(url.scheme == 'http' && local)) ||
        url.hasQuery ||
        url.hasFragment ||
        (url.path.isNotEmpty && url.path != '/')) {
      throw ArgumentError.value(input, 'baseUrl',
          'Use an HTTPS origin (or HTTP localhost for tests only).');
    }
    return url;
  }

  Uri _uri(String path) {
    final base = _baseUrl.toString().replaceFirst(RegExp(r'/$'), '');
    return Uri.parse('$base$path');
  }

  Map<String, dynamic> _jsonMap(String body) {
    final result = jsonDecode(body);
    if (result is! Map<String, dynamic>) {
      throw const FormatException('Invalid PocketBase response shape');
    }
    return result;
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
  }) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    if (requiresAuth) {
      final token = await _store.read();
      if (token == null || token.isEmpty) {
        throw const SccApiException(401, 'Login required');
      }
      headers['Authorization'] = token;
    }
    final response = await _http.send(
      http.Request(method, _uri(path))
        ..headers.addAll(headers)
        ..body = body == null ? '' : jsonEncode(body),
    );
    final output = await http.Response.fromStream(response);
    if (output.statusCode < 200 || output.statusCode >= 300) {
      if (output.statusCode == 401 && requiresAuth) {
        _currentUserId = null;
        await _store.write(null);
      }
      throw SccApiException(output.statusCode, 'PocketBase request failed');
    }
    return _jsonMap(output.body);
  }

  Future<SccUserSession> signIn(String email, String password) async {
    final result = await _request(
      'POST',
      '/api/collections/users/auth-with-password',
      body: {'identity': email, 'password': password},
      requiresAuth: false,
    );
    final token = result['token'];
    final record = result['record'];
    if (token is! String ||
        token.isEmpty ||
        record is! Map<String, dynamic>) {
      throw const FormatException('Invalid PocketBase login response');
    }
    final user = SccUserSession.fromJson(record);
    _currentUserId = user.id;
    await _store.write(token);
    return user;
  }

  Future<SccUserSession> refreshSession() async {
    final data = await _request(
      'POST',
      '/api/collections/users/auth-refresh',
    );
    final record = data['record'];
    final token = data['token'];
    if (token is! String || record is! Map<String, dynamic>) {
      throw const FormatException('Invalid PocketBase refresh response');
    }
    await _store.write(token);
    final user = SccUserSession.fromJson(record);
    _currentUserId = user.id;
    return user;
  }

  Future<void> signOut() async {
    _currentUserId = null;
    await _store.write(null);
  }

  Future<List<SccProduct>> listProducts({int page = 1, int perPage = 30}) async {
    if (page <= 0 || perPage <= 0 || perPage > 100) {
      throw ArgumentError('Invalid page or perPage');
    }
    final data = await _request(
      'GET', '/api/collections/products/records?page=$page&perPage=$perPage',
    );
    final items = data['items'];
    if (items is! List) {
      throw const FormatException('Missing products list');
    }
    return items
        .map((v) => SccProduct.fromJson(v as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<SccProduct> createProduct({
    required String title,
    required int priceMinor,
    String currency = 'YER',
    String description = '',
  }) async {
    if (title.trim().isEmpty || priceMinor < 0) {
      throw ArgumentError('Invalid product title or price');
    }
    final userId = _currentUserId ?? (await refreshSession()).id;
    final data = await _request('POST', '/api/collections/products/records',
        body: {
          'owner': userId,
          'title': title.trim(),
          'price_minor': priceMinor,
          'currency': currency,
          'description': description,
          'status': 'draft',
        });
    return SccProduct.fromJson(data);
  }

  /// Uploads private media. Access requires a PocketBase protected-file token.
  Future<String> uploadPrivateMedia({
    required List<int> bytes,
    required String filename,
    required String mimeType,
  }) async {
    final token = await _store.read();
    if (token == null || token.isEmpty) {
      throw const SccApiException(401, 'Login required');
    }
    if (bytes.isEmpty || bytes.length > 26214400) {
      throw ArgumentError('Invalid media size');
    }
    final userId = _currentUserId ?? (await refreshSession()).id;
    final request = http.MultipartRequest(
      'POST', _uri('/api/collections/media_assets/records'),
    );
    request.headers['Authorization'] = token;
    request.fields['owner'] = userId;
    request.files.add(http.MultipartFile.fromBytes(
      'file', bytes, filename: filename, contentType: MediaType.parse(mimeType),
    ));
    final response = await http.Response.fromStream(await _http.send(request));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SccApiException(response.statusCode, 'Media upload failed');
    }
    final json = _jsonMap(response.body);
    return json['id'] as String;
  }

  void close() => _http.close();
}
