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
  test('guest retry preserves device identity and parallel starts coalesce', () async {
    final identity = MemorySccTokenStore();
    final session = MemorySccTokenStore();
    final seen = <String>[];
    var failNext = true;
    final client = SccPocketBaseClient(baseUrl: 'https://creator-api.indexesstore.com',
      tokenStore: session, guestStore: identity,
      httpClient: MockClient((req) async {
        expect(req.url.path, '/api/scc/guest/session');
        expect(req.headers.containsKey('authorization'), isFalse);
        final secret = jsonDecode(req.body)['deviceSecret'] as String;
        expect(identity.token, secret); // persisted before network I/O
        seen.add(secret);
        if (failNext) { failNext = false; throw http.ClientException('offline'); }
        return http.Response(jsonEncode({'token': 'guest-token', 'record': {
          'id': 'guest-one', 'email': '', 'collectionName': 'users'
        }}), 200);
      }));
    addTearDown(client.close);
    await expectLater(client.startGuestSession(), throwsA(isA<http.ClientException>()));
    final attempts = await Future.wait([client.startGuestSession(), client.startGuestSession()]);
    expect(attempts.map((user) => user.id), everyElement('guest-one'));
    expect(seen.length, 2);
    expect(seen.toSet().length, 1);
    expect(seen.first, hasLength(43));
    expect(session.token, 'guest-token');
  });

  test('invalid guest response cannot store an administrator token', () async {
    final session = MemorySccTokenStore();
    final client = SccPocketBaseClient(baseUrl: 'https://creator-api.indexesstore.com',
      tokenStore: session, guestStore: MemorySccTokenStore(),
      httpClient: MockClient((req) async => http.Response(jsonEncode({
        'token': 'admin-token', 'record': {'id': 'admin', 'collectionName': '_superusers'}
      }), 200)));
    addTearDown(client.close);
    await expectLater(client.startGuestSession(), throwsFormatException);
    expect(session.token, isNull);
  });

  test('Google OAuth uses PKCE, validates state and saves a normal user', () async {
    final store = MemorySccTokenStore();
    String? verifier;
    final client = SccPocketBaseClient(
      baseUrl: 'https://creator-api.indexesstore.com', tokenStore: store,
      httpClient: MockClient((req) async {
        expect(req.headers.containsKey('authorization'), isFalse);
        if (req.url.path.endsWith('/auth-methods')) {
          return http.Response(jsonEncode({'oauth2': {'enabled': true, 'providers': [
            {'name': 'google', 'authURL': 'https://accounts.google.com/o/oauth2/auth?client_id=test&redirect_uri='}
          ]}}), 200);
        }
        expect(req.url.path, '/api/collections/users/auth-with-oauth2');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['codeVerifier'], verifier);
        expect(body['provider'], 'google');
        expect(body['redirectUrl'], 'https://creator-api.indexesstore.com/api/scc/oauth/google/callback');
        return http.Response(jsonEncode({'token': 'normal-token', 'record': {
          'id': 'normal-user', 'email': 'user@example.invalid', 'collectionName': 'users'
        }}), 200);
      }),
    );
    addTearDown(client.close);
    final request = await client.beginGoogleSignIn();
    verifier = request.codeVerifier;
    expect(request.authorizationUrl.queryParameters['code_challenge_method'], 'S256');
    expect(request.authorizationUrl.queryParameters['code_challenge'], hasLength(43));
    expect(request.authorizationUrl.queryParameters['code_challenge'], isNot(verifier));
    expect(request.state, hasLength(43));
    final callback = Uri.parse('com.indexes.scc://oauth/google?code=test-code&state=${request.state}');
    final user = await client.finishGoogleSignIn(request, callback);
    expect(user.id, 'normal-user');
    expect(store.token, 'normal-token');
    await expectLater(client.finishGoogleSignIn(request, callback), throwsStateError);
  });

  test('OAuth rejects wrong state, duplicates, expired and cancelled requests', () {
    SccGoogleAuthRequest transaction({DateTime? createdAt}) => SccGoogleAuthRequest(
      authorizationUrl: Uri.parse('https://accounts.google.com/o/oauth2/auth'),
      redirectUrl: 'https://creator-api.indexesstore.com/api/scc/oauth/google/callback',
      state: 'expected', codeVerifier: 'verifier', createdAt: createdAt,
    );
    for (final callback in [
      'com.indexes.scc://oauth/google?state=wrong&code=x',
      'com.indexes.scc://oauth/google?state=expected&state=expected&code=x',
      'com.indexes.scc://oauth/google?state=expected&code=x&code=y',
      'https://attacker.invalid/oauth/google?state=expected&code=x',
    ]) {
      expect(() => transaction().consumeCode(Uri.parse(callback)), throwsFormatException);
    }
    final valid = Uri.parse('com.indexes.scc://oauth/google?state=expected&code=x');
    expect(() => transaction(createdAt: DateTime.now().subtract(const Duration(minutes: 11))).consumeCode(valid), throwsFormatException);
    final cancelled = transaction()..cancel();
    expect(() => cancelled.consumeCode(valid), throwsStateError);
  });

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

