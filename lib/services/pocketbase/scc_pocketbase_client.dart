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


class SccMediaAsset {
  const SccMediaAsset({
    required this.id,
    required this.owner,
    required this.filename,
    required this.label,
  });

  final String id;
  final String owner;
  final String filename;
  final String label;

  factory SccMediaAsset.fromJson(Map<String, dynamic> source) => SccMediaAsset(
        id: source['id'] as String,
        owner: source['owner'] as String,
        filename: (source['file'] as String?) ?? '',
        label: (source['label'] as String?) ?? '',
      );
}

class SccContentItem {
  const SccContentItem({
    required this.id,
    required this.owner,
    required this.title,
    required this.body,
    required this.format,
    required this.status,
  });

  final String id;
  final String owner;
  final String title;
  final String body;
  final String format;
  final String status;

  factory SccContentItem.fromJson(Map<String, dynamic> source) =>
      SccContentItem(
        id: source['id'] as String,
        owner: source['owner'] as String,
        title: source['title'] as String,
        body: (source['body'] as String?) ?? '',
        format: (source['format'] as String?) ?? 'post',
        status: (source['status'] as String?) ?? 'draft',
      );
}

class SccAiResponse {
  const SccAiResponse({
    required this.jobId,
    required this.mode,
    required this.text,
  });

  final String jobId;
  final String mode;
  final String text;

  factory SccAiResponse.fromJson(Map<String, dynamic> source) => SccAiResponse(
        jobId: source['jobId'] as String,
        mode: source['mode'] as String,
        text: source['text'] as String,
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


  /// Calls the real authenticated server-side AI provider.
  /// Never includes a provider API key in the app or HTTP request body.
  Future<SccAiResponse> generateText({
    required String prompt,
    String mode = 'chat',
  }) async {
    const supported = [
      'chat', 'description', 'hashtags', 'ad', 'script', 'plan',
    ];
    if (prompt.trim().isEmpty || prompt.length > 6000) {
      throw ArgumentError('Prompt length must be between 1 and 6000.');
    }
    if (!supported.contains(mode)) {
      throw ArgumentError.value(mode, 'mode', 'Unsupported AI mode');
    }
    final value = await _request(
      'POST',
      '/api/scc/ai/text',
      body: {'mode': mode, 'prompt': prompt.trim()},
    );
    return SccAiResponse.fromJson(value);
  }

  Future<SccProduct> updateProduct({
    required String id,
    required String title,
    required int priceMinor,
    String currency = 'YER',
  }) async {
    if (id.trim().isEmpty || title.trim().isEmpty || priceMinor < 0) {
      throw ArgumentError('Invalid product information');
    }
    final data = await _request(
      'PATCH',
      '/api/collections/products/records/${Uri.encodeComponent(id)}',
      body: {
        'title': title.trim(),
        'price_minor': priceMinor,
        'currency': currency,
      },
    );
    return SccProduct.fromJson(data);
  }

  Future<void> deleteProduct(String id) async {
    if (id.trim().isEmpty) {
      throw ArgumentError('Missing product ID');
    }
    final token = await _store.read();
    if (token == null || token.isEmpty) {
      throw const SccApiException(401, 'Login required');
    }
    final response = await _http.delete(
      _uri('/api/collections/products/records/${Uri.encodeComponent(id)}'),
      headers: {'Authorization': token},
    );
    if (response.statusCode == 401) {
      _currentUserId = null;
      await _store.write(null);
    }
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw SccApiException(response.statusCode, 'Product delete failed');
    }
  }

  /// Personal content drafts are private per-user in PocketBase API rules.
  Future<List<SccContentItem>> listContentItems({
    int page = 1,
    int perPage = 30,
  }) async {
    if (page <= 0 || perPage <= 0 || perPage > 100) {
      throw ArgumentError('Invalid page or perPage');
    }
    final data = await _request(
      'GET',
      '/api/collections/content_items/records?page=$page&perPage=$perPage',
    );
    final items = data['items'];
    if (items is! List) {
      throw const FormatException('Missing content items list');
    }
    return items
        .map((entry) =>
            SccContentItem.fromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<SccContentItem> saveContentDraft({
    String? id,
    required String title,
    required String body,
    String format = 'post',
  }) async {
    const allowedFormats = ['post', 'reel', 'story', 'ad'];
    if (title.trim().isEmpty ||
        title.trim().length > 240 ||
        body.length > 30000 ||
        !allowedFormats.contains(format)) {
      throw ArgumentError('Invalid content draft');
    }
    final payload = <String, dynamic>{
      'title': title.trim(),
      'body': body,
      'format': format,
      'status': 'draft',
    };
    final isEditing = id != null && id.trim().isNotEmpty;
    if (!isEditing) {
      payload['owner'] = _currentUserId ?? (await refreshSession()).id;
    }
    final path = isEditing
        ? '/api/collections/content_items/records/' +
            Uri.encodeComponent(id)
        : '/api/collections/content_items/records';
    final result = await _request(
      isEditing ? 'PATCH' : 'POST',
      path,
      body: payload,
    );
    return SccContentItem.fromJson(result);
  }

  Future<void> deleteContentDraft(String id) async {
    if (id.trim().isEmpty) {
      throw ArgumentError('Missing content ID');
    }
    final token = await _store.read();
    if (token == null || token.isEmpty) {
      throw const SccApiException(401, 'Login required');
    }
    final response = await _http.delete(
      _uri('/api/collections/content_items/records/' +
          Uri.encodeComponent(id)),
      headers: {'Authorization': token},
    );
    if (response.statusCode == 401) {
      _currentUserId = null;
      await _store.write(null);
    }
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw SccApiException(
        response.statusCode,
        'Content delete failed',
      );
    }
  }

  Future<List<SccMediaAsset>> listPrivateMedia({
    int page = 1,
    int perPage = 30,
  }) async {
    if (page <= 0 || perPage <= 0 || perPage > 100) {
      throw ArgumentError('Invalid page or perPage');
    }
    final data = await _request(
      'GET',
      '/api/collections/media_assets/records?page=$page&perPage=$perPage',
    );
    final items = data['items'];
    if (items is! List) {
      throw const FormatException('Missing media list');
    }
    return items
        .map((v) => SccMediaAsset.fromJson(v as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Resolves private file bytes using a short-lived, user-scoped file token.
  /// Never returns a persistent public URL or superuser credentials.
  Future<List<int>> downloadPrivateImage(SccMediaAsset asset) async {
    final filename = asset.filename.toLowerCase();
    const extensions = ['.jpg', '.jpeg', '.png', '.webp'];
    if (!extensions.any(filename.endsWith)) {
      throw ArgumentError('Image preview supports JPG, PNG and WEBP only');
    }
    if (asset.id.isEmpty || asset.filename.isEmpty) {
      throw ArgumentError('Invalid media record');
    }

    // PocketBase issues short-lived file tokens only to authenticated users.
    final result = await _request(
      'POST',
      '/api/files/token',
      body: const <String, dynamic>{},
    );
    final fileToken = result['token'];
    if (fileToken is! String || fileToken.isEmpty) {
      throw const FormatException('Missing protected file token');
    }
    final path = '/api/files/media_assets/' +
        Uri.encodeComponent(asset.id) +
        '/' +
        Uri.encodeComponent(asset.filename) +
        '?token=' +
        Uri.encodeQueryComponent(fileToken);
    final response = await _http.get(
      _uri(path),
      headers: {'Accept': 'image/*', 'Cache-Control': 'no-store'},
    );
    if (response.statusCode != 200) {
      throw SccApiException(response.statusCode, 'Protected image read denied');
    }
    if (response.bodyBytes.isEmpty || response.bodyBytes.length > 26214400) {
      throw const FormatException('Invalid protected image payload');
    }
    return response.bodyBytes;
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
