/// 3:07, or 1:02:45 for long ones.
String clock(Duration d) {
  final s = d.inSeconds.abs();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final ss = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// "1 hr 12 min" / "42 min".
String total(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h hr' : '$h hr $m min';
}

String plural(int n, String word) => '$n ${n == 1 ? word : '${word}s'}';
