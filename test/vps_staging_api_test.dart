import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:smart_content_creator/services/vps_staging_api.dart';

void main() {
  test('is disabled by default and does not make network requests', () async {
    var requests = 0;
    final mock = MockClient((_) async {
      requests++;
      return http.Response('unexpected', 500);
    });
    final api = VpsStagingApi(baseUrl: '', client: mock);
    expect(api.isConfigured, isFalse);
    expect(await api.checkHealth(), isFalse);
    expect(requests, 0);
    mock.close();
  });

  test('rejects insecure URLs', () {
    expect(
      () => VpsStagingApi(baseUrl: 'http://example.org'),
      throwsArgumentError,
    );
    expect(
      () => VpsStagingApi(baseUrl: 'https://user:pass@example.org'),
      throwsArgumentError,
    );
  });

  test('accepts a healthy HTTPS response', () async {
    final mock = MockClient((request) async {
      expect(request.url.toString(), 'https://test.example.org/healthz');
      expect(request.headers.containsKey('Authorization'), isFalse);
      return http.Response(
        '{"status":"ok","service":"scc-staging"}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = VpsStagingApi(
      baseUrl: 'https://test.example.org',
      client: mock,
    );
    expect(api.isConfigured, isTrue);
    expect(await api.checkHealth(), isTrue);
    mock.close();
  });

  test('fails closed for unhealthy responses', () async {
    final mock = MockClient((_) async => http.Response('{"status":"fail"}', 503));
    final api = VpsStagingApi(
      baseUrl: 'https://test.example.org',
      client: mock,
    );
    expect(await api.checkHealth(), isFalse);
    mock.close();
  });
}
