import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:smart_content_creator/services/vps_auth_preview_client.dart';

void main() {
  const token = 'temporary-preview-token-0123456789abcdef0123456789';

  test('disabled by default: no credentials or requests are sent', () async {
    var requests = 0;
    final mock = MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    final client = VpsAuthPreviewClient(baseUrl: '', client: mock);
    expect(client.isConfigured, isFalse);
    expect(await client.login(email: 'test@example.org', password: 'secret'),
        isFalse);
    expect(requests, 0);
    client.dispose();
    mock.close();
  });

  test('rejects HTTP and credentials in URLs', () {
    expect(
      () => VpsAuthPreviewClient(baseUrl: 'http://example.org'),
      throwsArgumentError,
    );
    expect(
      () => VpsAuthPreviewClient(baseUrl: 'https://user:pass@example.org'),
      throwsArgumentError,
    );
  });

  test('login then fetch user/products with token scoped to same HTTPS host',
      () async {
    final requested = <String>[];
    final mock = MockClient((req) async {
      requested.add(req.url.path);
      expect(req.url.host, 'test.example.org');
      if (req.url.path == '/v1/auth/login') {
        expect(req.headers.containsKey('Authorization'), isFalse);
        expect(jsonDecode(req.body)['email'], 'alice@example.org');
        return http.Response(jsonEncode({'access_token': token}), 200);
      }
      expect(req.headers['Authorization'], 'Bearer $token');
      if (req.url.path == '/v1/auth/me') {
        return http.Response(
            jsonEncode({
              'user': {'id': 'u1', 'email': 'alice@example.org', 'role': 'member'}
            }),
            200);
      }
      if (req.url.path == '/v1/products') {
        return http.Response(jsonEncode({'items': []}), 200);
      }
      return http.Response('{}', 404);
    });
    final client = VpsAuthPreviewClient(
        baseUrl: 'https://test.example.org', client: mock);
    expect(await client.login(
        email: 'alice@example.org', password: 'ExamplePassphrase2026!'), isTrue);
    expect(client.hasSession, isTrue);
    expect((await client.getCurrentUser())?['role'], 'member');
    expect(await client.listProducts(), isEmpty);
    expect(requested,
        ['/v1/auth/login', '/v1/auth/me', '/v1/products']);
    client.dispose();
    mock.close();
  });

  test('draft creation includes no owner or role client-side', () async {
    final mock = MockClient((req) async {
      if (req.url.path == '/v1/auth/login') {
        return http.Response(jsonEncode({'access_token': token}), 200);
      }
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body.keys, unorderedEquals([
        'title', 'price_decimal', 'currency', 'quantity',
      ]));
      expect(req.headers['Authorization'], 'Bearer $token');
      return http.Response(jsonEncode({'product': {'id': 'p1', ...body}}), 201);
    });
    final client = VpsAuthPreviewClient(
        baseUrl: 'https://test.example.org', client: mock);
    expect(await client.login(email: 'test@example.org', password: 'pass'), isTrue);
    expect((await client.createDraft(
      title: 'Test product', priceDecimal: '1290', quantity: 3,
    ))['id'], 'p1');
    client.dispose();
    mock.close();
  });

  test('401 revokes local session', () async {
    final mock = MockClient((req) async {
      if (req.url.path == '/v1/auth/login') {
        return http.Response(jsonEncode({'access_token': token}), 200);
      }
      return http.Response('{}', 401);
    });
    final client = VpsAuthPreviewClient(
        baseUrl: 'https://test.example.org', client: mock);
    expect(await client.login(email: 'test@example.org', password: 'pass'), isTrue);
    expect(await client.getCurrentUser(), isNull);
    expect(client.hasSession, isFalse);
    client.dispose();
    mock.close();
  });
}
