import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:smart_content_creator/scc_pocketbase_app.dart';
import 'package:smart_content_creator/services/pocketbase/scc_pocketbase_client.dart';

class FakeSccTokenStore implements SccTokenStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? token) async { value = token; }
}

void main() {
  testWidgets('real PocketBase login and product screen, without Firebase',
      (tester) async {
    final saved = FakeSccTokenStore();
    final products = <Map<String, dynamic>>[];
    final drafts = <Map<String, dynamic>>[];
    final requests = <String>[];
    final backend = MockClient((request) async {
      requests.add(request.method + ' ' + request.url.path);
      final path = request.url.path;
      if (path.endsWith('/auth-with-password')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['identity'], 'user@example.invalid');
        return http.Response(
          jsonEncode({
            'token': 'owner-token',
            'record': {'id': 'test-user-1', 'email': 'user@example.invalid'}
          }),
          200,
        );
      }
      if (path.endsWith('/products/records') && request.method == 'GET') {
        expect(request.headers['authorization'], 'owner-token');
        return http.Response(
          jsonEncode({'items': products}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (path.endsWith('/products/records') && request.method == 'POST') {
        final data = jsonDecode(request.body) as Map<String, dynamic>;
        expect(data['owner'], 'test-user-1');
        products.add({
          'id': 'product-1',
          'owner': data['owner'],
          'title': data['title'],
          'price_minor': data['price_minor'],
          'currency': data['currency'],
          'status': 'draft'
        });
        return http.Response(
          jsonEncode(products.last),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }

      if (path.endsWith('/content_items/records') &&
          request.method == 'GET') {
        expect(request.headers['authorization'], 'owner-token');
        return http.Response(
          jsonEncode({'items': drafts}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (path.endsWith('/content_items/records') &&
          request.method == 'POST') {
        expect(request.headers['authorization'], 'owner-token');
        final input = jsonDecode(request.body) as Map<String, dynamic>;
        expect(input['owner'], 'test-user-1');
        expect(input['status'], 'draft');
        drafts.add({
          'id': 'draft-1', 'owner': input['owner'],
          'title': input['title'], 'body': input['body'],
          'format': input['format'], 'status': input['status'],
        });
        return http.Response(
          jsonEncode(drafts.last),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (path.endsWith('/media_assets/records')) {
        return http.Response('{"items":[]}', 200);
      }
      fail('Unexpected endpoint ' + path);
    });
    final client = SccPocketBaseClient(
      baseUrl: 'https://creator-api.indexesstore.com',
      httpClient: backend,
      tokenStore: saved,
    );
    addTearDown(() {
      client.close();
    });
    await tester.pumpWidget(SccPocketBaseApp(client: client));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('scc-login-google')), findsOneWidget);
    expect(find.byKey(const Key('scc-login-email')), findsNothing);
    await tester.tap(find.byKey(const Key('scc-login-password-option')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scc-login-email')), findsOneWidget);
    expect(find.text('إضافة منتج'), findsNothing);
    await tester.enterText(
      find.byKey(const Key('scc-login-email')), 'user@example.invalid',
    );
    await tester.enterText(
      find.byKey(const Key('scc-login-password')), 'test-secret',
    );
    await tester.tap(find.byKey(const Key('scc-login-submit')));
    await tester.pumpAndSettle();

    expect(saved.value, 'owner-token');
    expect(find.byKey(const Key('scc-add-product')), findsOneWidget);
    expect(find.text('لا توجد منتجات في حسابك'), findsOneWidget);
    await tester.tap(find.byKey(const Key('scc-add-product')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('scc-product-title')), 'منتج أصلي',
    );
    await tester.enterText(
      find.byKey(const Key('scc-product-price')), '14000',
    );
    await tester.tap(find.byKey(const Key('scc-save-product')));
    await tester.pumpAndSettle();

    expect(find.text('منتج أصلي'), findsOneWidget);
    expect(find.textContaining('14000'), findsOneWidget);
    expect(products.length, 1);

    // Real content drafts tab uses the backend collection, not local demo data.
    await tester.tap(find.text('المحتوى').last);
    await tester.pumpAndSettle();
    expect(find.text('لا توجد مسودات محتوى بعد'), findsOneWidget);
    await tester.tap(find.byKey(const Key('scc-add-content')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('scc-content-title')), 'إعلان أصلي',
    );
    await tester.enterText(
      find.byKey(const Key('scc-content-body')), 'وصف منتج باللغة العربية',
    );
    await tester.tap(find.byKey(const Key('scc-save-content')));
    await tester.pumpAndSettle();
    expect(find.text('إعلان أصلي'), findsOneWidget);
    expect(drafts.length, 1);
    expect(drafts.single['status'], 'draft');
    await tester.tap(find.text('الحساب').last);
    await tester.pumpAndSettle();
    expect(find.text('user@example.invalid'), findsOneWidget);
    await tester.tap(find.byKey(const Key('scc-signout')));
    await tester.pumpAndSettle();

    expect(saved.value, isNull);
    expect(find.byKey(const Key('scc-login-email')), findsOneWidget);
    expect(requests, contains('POST /api/collections/products/records'));
    expect(requests, contains('POST /api/collections/content_items/records'));
  });
}

