import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';

void main() {
  test('server config is accepted with or without the QR prefix', () {
    final encoded =
        ServerConfig(idServer: 'id.example.com', key: 'abc').encode();

    expect(tryDecodeServerConfig(encoded)?.idServer, 'id.example.com');
    expect(tryDecodeServerConfig('config=$encoded')?.key, 'abc');
    expect(tryDecodeServerConfig('https://example.com/page'), isNull);
  });
}
