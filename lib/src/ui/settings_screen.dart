import 'package:flutter/material.dart';

import 'app_scope.dart';

/// App settings: sunlight mode, render DPI, coordinate format, about.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _SectionTitle('Display'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Sunlight mode'),
                  subtitle: const Text(
                      'Extra contrast for bright outdoor use'),
                  value: settings.sunlightMode,
                  onChanged: (v) async {
                    await settings.setSunlightMode(v);
                    if (mounted) setState(() {});
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Restart the app to apply the theme change'),
                        ),
                      );
                    }
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Coordinate format'),
                  subtitle: Text(settings.coordFormat == 'utm'
                      ? 'UTM (e.g. 48S 699163mE 9314349mN)'
                      : 'Latitude / longitude'),
                  trailing: DropdownButton<String>(
                    value: settings.coordFormat,
                    items: const [
                      DropdownMenuItem(
                          value: 'utm', child: Text('UTM')),
                      DropdownMenuItem(
                          value: 'latlon', child: Text('Lat/Lon')),
                    ],
                    onChanged: (v) async {
                      if (v == null) return;
                      await settings.setCoordFormat(v);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _SectionTitle('Map rendering'),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Overlay render quality'),
                  subtitle: Text(
                      '${settings.renderDpi.toStringAsFixed(0)} DPI — '
                      'higher is sharper but slower'),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [96, 150, 300].map((dpi) {
                      final selected =
                          settings.renderDpi == dpi.toDouble();
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4),
                          child: ChoiceChip(
                            label: Text('$dpi'),
                            selected: selected,
                            onSelected: (_) async {
                              await settings
                                  .setRenderDpi(dpi.toDouble());
                              if (mounted) setState(() {});
                            },
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _SectionTitle('About'),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Patok 0.1.0',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  SizedBox(height: 8),
                  Text(
                    'Offline georeferenced map reader for Android.\n'
                    'Reads OGC georegistration (/VP /Measure) and '
                    'TerraGo (/LGIDict) PDFs. Maps render with PDFium; '
                    'coordinates reprojected with PROJ.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(color: Theme.of(context).colorScheme.primary)),
    );
  }
}
