import 'package:flutter_hbb/mobile/widgets/session_panel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('network info names the tested NAT type and IPv6', () {
    final sym = readNetworkInfo('{"nat_type":2,"ipv6":true}');
    expect(sym.natLabel, 'Symmetric NAT');
    expect(sym.ipv6, isTrue);
    final cone = readNetworkInfo('{"nat_type":1,"ipv6":false}');
    expect(cone.natLabel, 'Asymmetric NAT');
    expect(cone.ipv6, isFalse);
    expect(readNetworkInfo('{}').natLabel, 'Untested');
    expect(readNetworkInfo('not json').natLabel, 'Untested');
  });

  test('status line names the direct channel, not the relay', () {
    expect(sessionChannelLabel('IPv6'), 'IPv6');
    expect(sessionChannelLabel('TCP'), 'TCP');
    expect(sessionChannelLabel('Relay'), '');
  });
}
