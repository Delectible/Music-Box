import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/crash_log.dart';

/// Errors and crashes Roadie has recorded, to copy and send when something
/// goes wrong.
class ProblemsScreen extends StatefulWidget {
  const ProblemsScreen({super.key});

  @override
  State<ProblemsScreen> createState() => _ProblemsScreenState();
}

class _ProblemsScreenState extends State<ProblemsScreen> {
  String? _text;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await CrashLog.read();
    if (mounted) setState(() => _text = t);
  }

  @override
  Widget build(BuildContext context) {
    final t = _text;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Problem reports'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_rounded),
            onPressed: t == null || t.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: t));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                  },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: t == null || t.isEmpty
                ? null
                : () async {
                    await CrashLog.clear();
                    await _load();
                  },
          ),
        ],
      ),
      body: t == null
          ? const Center(child: CircularProgressIndicator())
          : t.isEmpty
          ? const Center(child: Text('No problems recorded'))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(t, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            ),
    );
  }
}
