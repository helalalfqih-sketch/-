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

  test('private content: list, edit without owner spoofing, and delete',
      () async {
    final store = MemorySccTokenStore()..token = 'normal-user-token';
    final calls = <String>[];
    final api = SccPocketBaseClient(
      baseUrl: 'https://creator-api.indexesstore.com',
      tokenStore: store,
      httpClient: MockClient((req) async {
        calls.add(req.method + ' ' + req.url.path);
        expect(req.headers['authorization'], 'normal-user-token');
        if (req.method == 'GET') {
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 'draft-a',
                  'owner': 'user-a',
                  'title': 'محتوى خاص',
                  'body': 'مسودة قديمة',
                  'format': 'post',
                  'status': 'draft',
                }
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.method == 'PATCH') {
          final data = jsonDecode(req.body) as Map<String, dynamic>;
          expect(data.containsKey('owner'), isFalse);
          expect(data['status'], 'draft');
          return http.Response(
            jsonEncode({
              'id': 'draft-a',
              'owner': 'user-a',
              'title': data['title'],
              'body': data['body'],
              'format': data['format'],
              'status': 'draft',
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.method == 'DELETE') {
          return http.Response('', 204);
        }
        fail('Unexpected draft operation');
      }),
    );
    final list = await api.listContentItems();
    expect(list.single.title, 'محتوى خاص');
    final updated = await api.saveContentDraft(
      id: 'draft-a',
      title: 'مسودة معدلة',
      body: 'تحديث خاص',
      format: 'ad',
    );
    expect(updated.body, 'تحديث خاص');
    expect(updated.format, 'ad');
    await api.deleteContentDraft('draft-a');
    expect(calls, [
      'GET /api/collections/content_items/records',
      'PATCH /api/collections/content_items/records/draft-a',
      'DELETE /api/collections/content_items/records/draft-a',
    ]);
    api.close();
  });

  test('rejects invalid content without contacting the server', () async {
    final store = MemorySccTokenStore();
    final api = SccPocketBaseClient(
      baseUrl: 'https://creator-api.indexesstore.com',
      tokenStore: store,
      httpClient: MockClient((req) async {
        fail('Invalid drafts must not reach the network');
      }),
    );
    await expectLater(
      api.saveContentDraft(title: '', body: 'body'),
      throwsArgumentError,
    );
    await expectLater(
      api.saveContentDraft(title: 'Valid', body: 'text', format: 'unsafe'),
      throwsArgumentError,
    );
    api.close();
  });


  test('private image preview uses a short-lived user-scoped file token',
      () async {
    final store = MemorySccTokenStore()..token = 'regular-user-token';
    final operations = <String>[];
    final api = SccPocketBaseClient(
      baseUrl: 'https://creator-api.indexesstore.com',
      tokenStore: store,
      httpClient: MockClient((request) async {
        operations.add(request.method + ' ' + request.url.path);
        if (request.method == 'POST') {
          expect(request.url.path, '/api/files/token');
          expect(request.headers['authorization'], 'regular-user-token');
          return http.Response('{"token":"temporary-media-token"}', 200);
        }
        expect(request.method, 'GET');
        expect(request.url.path,
            '/api/files/media_assets/asset-one/owner-only.png');
        expect(request.url.queryParameters['token'],
            'temporary-media-token');
        expect(request.headers['cache-control'], 'no-store');
        return http.Response.bytes(
          <int>[137, 80, 78, 71, 13, 10, 26, 10],
          200,
          headers: {'content-type': 'image/png'},
        );
      }),
    );
    final bytes = await api.downloadPrivateImage(const SccMediaAsset(
      id: 'asset-one',
      owner: 'user-one',
      filename: 'owner-only.png',
      label: 'صورة خاصة',
    ));
    expect(bytes.length, 8);
    expect(operations, [
      'POST /api/files/token',
      'GET /api/files/media_assets/asset-one/owner-only.png',
    ]);
    api.close();
  });

  test('private preview refuses videos before requesting file tokens',
      () async {
    final api = SccPocketBaseClient(
      baseUrl: 'https://creator-api.indexesstore.com',
      tokenStore: MemorySccTokenStore(),
      httpClient: MockClient((req) async {
        fail('Video preview must be refused locally');
      }),
    );
    await expectLater(
      api.downloadPrivateImage(const SccMediaAsset(
        id: 'asset-video',
        owner: 'user-one',
        filename: 'private-video.mp4',
        label: 'فيديو خاص',
      )),
      throwsArgumentError,
    );
    api.close();
  });

}
