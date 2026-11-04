import 'package:flutter/material.dart';

import '../services/alarm_bridge.dart';

/// What's installed. The version comes from Android, so it always matches App info,
/// including the -debug suffix debug builds get (see android/app/build.gradle.kts).
class InfoPage extends StatelessWidget {
  const InfoPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Info')),
        body: ListView(
          children: [
            ListTile(
              title: const Text('Version'),
              subtitle: FutureBuilder<String>(
                future: AlarmBridge.appVersion(),
                builder: (_, snapshot) => Text(
                  snapshot.data ?? (snapshot.hasError ? 'Unknown' : '…'),
                ),
              ),
            ),
            const ListTile(
              title: Text('Source code'),
              subtitle: SelectableText('github.com/SusieeTheLinuxUser/dosekeeper'),
            ),
            const ListTile(title: Text('License'), subtitle: Text('MIT')),
            const ListTile(
              title: Text('Your data'),
              subtitle: Text(
                'Stays on this phone and in the backup folder you choose. '
                'No account, no server.',
              ),
            ),
            const ListTile(
              title: Text('Not a medical device'),
              subtitle: Text(
                'DoseKeeper is a reminder. It gives no dosing advice.',
              ),
            ),
          ],
        ),
      );
}
