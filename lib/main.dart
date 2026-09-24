import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'services/alarm_bridge.dart';
import 'services/scheduler.dart';
import 'ui/backup_page.dart';
import 'ui/medications_page.dart';
import 'ui/today_page.dart';

void main() => runApp(const DoseKeeperApp());

class DoseKeeperApp extends StatelessWidget {
  const DoseKeeperApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'DoseKeeper',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6EE7A8),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const HomeShell(),
      );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  final _scheduler = DoseScheduler();
  final _todayKey = GlobalKey<TodayPageState>();
  final _medsKey = GlobalKey<MedicationsPageState>();
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Alarms fire while the app is closed, so the Today view can be stale whenever
  /// the user comes back. Re-sync on every resume.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _todayKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      TodayPage(key: _todayKey, scheduler: _scheduler),
      MedicationsPage(
        key: _medsKey,
        scheduler: _scheduler,
        onChanged: () => _todayKey.currentState?.refresh(),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('DoseKeeper'),
        actions: [
          IconButton(
            tooltip: 'Backup & restore',
            icon: const Icon(Icons.backup_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => BackupPage(scheduler: _scheduler),
                ),
              );
              // A restore may have replaced everything both tabs show.
              _todayKey.currentState?.refresh();
              _medsKey.currentState?.refresh();
            },
          ),
          // Fires a real alarm through the real pipeline, to verify it rings on
          // this device. Debug builds only -- not something a user should need.
          // Confirms first: this sits on the app bar on every screen, and an
          // accidental tap would otherwise fire a real ringing alarm unprompted.
          if (kDebugMode)
            IconButton(
              tooltip: 'Test alarm (10s)',
              icon: const Icon(Icons.alarm_add),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Fire test alarm?'),
                    content: const Text('Rings for real in 10 seconds.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Fire'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) await AlarmBridge.testAlarm(10);
              },
            ),
        ],
      ),
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          if (i == 0) _todayKey.currentState?.refresh();
          if (i == 1) _medsKey.currentState?.refresh();
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today), label: 'Today'),
          NavigationDestination(
            icon: Icon(Icons.medication_outlined),
            label: 'Medications',
          ),
        ],
      ),
    );
  }
}
