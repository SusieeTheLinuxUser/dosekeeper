import 'dart:math';

import 'package:flutter/material.dart';

import '../services/alarm_bridge.dart';

/// What's installed. The version comes from Android, so it always matches App info,
/// including the -debug suffix debug builds get (see android/app/build.gradle.kts).
class InfoPage extends StatefulWidget {
  const InfoPage({super.key});

  static const sourceUrl = 'https://github.com/SusieeTheLinuxUser/dosekeeper';

  /// [roll] is a random number from 0 up to 1. One roll in 10,000 gets the rare line.
  static String easterEgg(double roll) => roll < 1e-4
      ? 'You expected an Easter Egg but it was me... Dio!'
      : 'But nobody came...';

  @override
  State<InfoPage> createState() => _InfoPageState();
}

class _InfoPageState extends State<InfoPage> {
  final _version = AlarmBridge.appVersion();
  var _snoozeMinutes = AlarmBridge.getSnoozeMinutes();
  var _versionTaps = 0;

  /// Android makes you a developer after tapping the build number. Here, nobody came.
  void _tapVersion() {
    if (++_versionTaps % 10 != 0) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(InfoPage.easterEgg(Random().nextDouble()))));
  }

  Future<void> _openSource() async {
    final opened = await AlarmBridge.openUrl(InfoPage.sourceUrl);
    if (opened || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No browser found to open the link.')),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Info')),
        body: ListView(
          children: [
            ListTile(
              title: const Text('Version'),
              onTap: _tapVersion,
              subtitle: FutureBuilder<String>(
                future: _version,
                builder: (_, snapshot) => Text(
                  snapshot.data ?? (snapshot.hasError ? 'Unknown' : '…'),
                ),
              ),
            ),
            ListTile(
              title: const Text('Source code'),
              subtitle: const Text('github.com/SusieeTheLinuxUser/dosekeeper'),
              trailing: const Icon(Icons.open_in_new),
              onTap: _openSource,
            ),
            // How long the alarm screen's Snooze waits before ringing again.
            // Native-backed (see AlarmBridge.getSnoozeMinutes): the alarm screen
            // snoozes without Dart running.
            ListTile(
              title: const Text('Snooze length'),
              subtitle: const Text('How long the alarm waits before ringing again'),
              trailing: FutureBuilder<int>(
                future: _snoozeMinutes,
                builder: (_, snapshot) => PopupMenuButton<int>(
                  initialValue: snapshot.data,
                  tooltip: 'Snooze length',
                  onSelected: (minutes) async {
                    await AlarmBridge.setSnoozeMinutes(minutes);
                    if (!mounted) return;
                    setState(() => _snoozeMinutes = AlarmBridge.getSnoozeMinutes());
                  },
                  itemBuilder: (_) => [
                    for (final m in AlarmBridge.snoozeChoices)
                      PopupMenuItem(value: m, child: Text('$m min')),
                  ],
                  child: Text(
                    snapshot.data == null ? '…' : '${snapshot.data} min',
                  ),
                ),
              ),
            ),
            const ListTile(title: Text('License'), subtitle: Text('MIT')),
            const ListTile(
              title: Text('Your data'),
              subtitle: Text(
                'Stored on this phone, plus the backup folder and Google backup '
                'if you turn them on. DoseKeeper has no account or server.',
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
