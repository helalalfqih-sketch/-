import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_content_creator/services/pocketbase/scc_pocketbase_client.dart';

class MemorySccTokenStore implements SccTokenStore {
  String? token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String? next) async { token = next; }
}

void main() {
  test('rejects non-HTTPS remote servers', () {
    expect(
      () => SccPocketBaseClient(
        baseUrl: 'http://creator-api.indexesstore.com',
        tokenStore: MemorySccTokenStore(),
      ),
      throwsArgumentError,
    );
    expect(
      () => SccPocketBaseClient(
        baseUrl: 'https://creator-api.indexesstore.com/api',
        tokenStore: MemorySccTokenStore(),
      ),
      throwsArgumentError,
    );
  });

  test('requires user authentication before accessing products', () async {
    final store = MemorySccTokenStore();
    final client = SccPocketBaseClient(
      baseUrl: 'https://creator-api.indexesstore.com',
      tokenStore: store,
      httpClient: MockClient((request) async {
        fail('Must not access the network while logged out');
      }),
    );
    await expectLater(
      client.listProducts(),
      throwsA(isA<SccApiException>().having(
        (e) => e.statusCode, 'statusCode', 401,
      )),
    );
    client.close();
  });

  test('signs in using a normal user, creates private draft product', () async {
    final store = MemorySccTokenStore();
    final requests = <http.Request>[];
    final transport = MockClient((req) async {
      requests.add(req);
      if (req.url.path.endsWith('/auth-with-password')) {
        expect(req.headers.containsKey('authorization'), isFalse);
        final credentials = jsonDecode(req.body) as Map<String, dynamic>;
        expect(credentials['identity'], 'owner@example.invalid');
        return http.Response(jsonEncode({
          'token': 'user-scope-token',
          'record': {'id': 'ownerA123', 'email': 'owner@example.invalid'}
        }), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }
      if (req.method == 'POST' && req.url.path.endsWith('/products/records')) {
        expect(req.headers['authorization'], 'user-scope-token');
        final data = jsonDecode(req.body) as Map<String, dynamic>;
        expect(data['owner'], 'ownerA123');
        expect(data['status'], 'draft');
        expect(data['price_minor'], 129900);
        return http.Response(jsonEncode({
          'id': 'prod123', 'owner': data['owner'],
          'title': data['title'], 'price_minor': data['price_minor'],
          'status': data['status'], 'currency': data['currency']
        }), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }
      if (req.method == 'GET' && req.url.path.endsWith('/products/records')) {
        expect(req.headers['authorization'], 'user-scope-token');
        return http.Response(jsonEncode({
          'items': [
            {'id': 'prod123', 'owner': 'ownerA123', 'title': 'منتج خاص',
             'price_minor': 129900, 'currency': 'YER', 'status': 'draft'}
          ]
        }), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }
      fail('Unexpected client request');
    });
    final client = SccPocketBaseClient(
      baseUrl: 'https://creator-api.indexesstore.com',
      httpClient: transport, tokenStore: store,
    );
    final user = await client.signIn('owner@example.invalid', 'test-password');
    expect(user.id, 'ownerA123');
    expect(store.token, 'user-scope-token');
    final product = await client.createProduct(
      title: 'منتج خاص', priceMinor: 129900,
    );
    expect(product.owner, user.id);
    expect(product.status, 'draft');
    expect((await client.listProducts()).single.id, product.id);
    expect(requests.length, 3);
    await client.signOut();
    expect(store.token, isNull);
    client.close();
  });

  test('refreshes user session without persisting superuser secrets', () async {
    final store = MemorySccTokenStore()..token = 'old-user-token';
    final client = SccPocketBaseClient(
      baseUrl: 'https://creator-api.indexesstore.com',
      tokenStore: store,
      httpClient: MockClient((req) async {
        expect(req.url.path, '/api/collections/users/auth-refresh');
        expect(req.headers['authorization'], 'old-user-token');
        return http.Response(jsonEncode({
          'token': 'renewed-user-token',
          'record': {'id': 'ownerA123', 'email': 'owner@example.invalid'}
        }), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );
    final session = await client.refreshSession();
    expect(session.id, 'ownerA123');
    expect(store.token, 'renewed-user-token');
    client.close();
  });

  test('401 clears expired token', () async {
    final store = MemorySccTokenStore()..token = 'expired';
    final client = SccPocketBaseClient(
      baseUrl: 'https://creator-api.indexesstore.com',
      tokenStore: store,
      httpClient: MockClient((req) async {
        return http.Response('{"message":"unauthorized"}', 401);
      }),
    );
    await expectLater(client.listProducts(), throwsA(
      isA<SccApiException>().having((e) => e.statusCode, 'statusCode', 401),
    ));
    expect(store.token, isNull);
    client.close();
  });
}
