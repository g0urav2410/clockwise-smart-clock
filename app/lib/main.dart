import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/clock_controller.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'screens/automations_screen.dart';
import 'screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(ClockApp(initialMode: _modeFrom(prefs.getString('theme_mode'))));
}

ThemeMode _modeFrom(String? s) => switch (s) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

class ClockApp extends StatefulWidget {
  final ThemeMode initialMode;
  const ClockApp({super.key, required this.initialMode});

  static ClockAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<ClockAppState>();

  @override
  State<ClockApp> createState() => ClockAppState();
}

class ClockAppState extends State<ClockApp> {
  late ThemeMode themeMode = widget.initialMode;

  Future<void> setThemeMode(ThemeMode m) async {
    setState(() => themeMode = m);
    final p = await SharedPreferences.getInstance();
    await p.setString('theme_mode', m.name);
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ClockController()..init()),
      ],
      child: MaterialApp(
        title: 'Clockwise',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: themeMode,
        home: const _Shell(),
      ),
    );
  }
}

/// Two tabs plus a settings gear in the app bar — deliberately minimal.
class _Shell extends StatefulWidget {
  const _Shell();
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> with WidgetsBindingObserver {
  int _tab = 0;

  static const _screens = [HomeScreen(), AutomationsScreen()];
  static const _labels = ['Home', 'Automations'];
  static const _icons = [Icons.home_outlined, Icons.auto_awesome_outlined];
  static const _iconsA = [Icons.home, Icons.auto_awesome];

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

  /// Stop polling the clock while the app isn't on screen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    context.read<ClockController>().setForeground(state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: c.card,
              border: Border.all(color: c.cardBorder, width: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.watch_outlined, size: 16, color: c.accent),
          ),
          const SizedBox(width: 10),
          Text(
            ctl.hasDevice ? ctl.current!.name : 'Clockwise',
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w500, color: c.title),
          ),
        ]),
        actions: [
          IconButton(
            icon: Icon(Icons.settings_outlined, size: 20, color: c.muted),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      // IndexedStack, not _screens[_tab]: keeps every tab's State and scroll
      // position alive so switching tabs doesn't reset them.
      body: IndexedStack(index: _tab, children: _screens),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: c.navBg,
          border: Border(top: BorderSide(color: c.navBorder, width: 0.5)),
        ),
        child: SafeArea(
          child: Row(
            children: List.generate(
              _screens.length,
              (i) => Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _tab = i),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_tab == i ? _iconsA[i] : _icons[i],
                          size: 22, color: _tab == i ? c.accent : c.muted),
                      const SizedBox(height: 3),
                      Text(_labels[i],
                          style: TextStyle(
                            fontSize: 10,
                            color: _tab == i ? c.accent : c.muted,
                            fontWeight:
                                _tab == i ? FontWeight.w500 : FontWeight.normal,
                          )),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
