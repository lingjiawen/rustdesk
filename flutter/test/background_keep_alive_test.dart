import 'package:flutter_hbb/mobile/widgets/background_keep_alive.dart';
import 'package:flutter_hbb/utils/ios_container_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('only a long suspension costs the connection', (tester) async {
    var now = DateTime(2026);
    final guard = SessionBackgroundGuard(now: () => now);
    Future<void> run(Duration time) async {
      now = now.add(time);
      await tester.pump(time);
    }

    // Kept running all the while, however long.
    guard.onBackground();
    await run(const Duration(minutes: 10));
    expect(guard.onForeground(), isFalse);

    // Suspended, but not for long enough for the remote side to give up.
    guard.onBackground();
    await run(const Duration(seconds: 30));
    now = now.add(const Duration(seconds: 20));
    expect(guard.onForeground(), isFalse);

    guard.onBackground();
    await run(const Duration(seconds: 30));
    now = now.add(const Duration(seconds: 40));
    expect(guard.onForeground(), isTrue);
    expect(guard.onForeground(), isFalse);
  });

  test('a saved path follows the app container', () {
    const home = '/var/mobile/Containers/Data/Application/NEW/Documents/data';
    expect(
        rebaseIosContainerPath(
            '/private/var/mobile/Containers/Data/Application/OLD/Documents/data/a/b.zip',
            home),
        '/var/mobile/Containers/Data/Application/NEW/Documents/data/a/b.zip');
    expect(rebaseIosContainerPath('/tmp/b.zip', home), '/tmp/b.zip');
  });
}
