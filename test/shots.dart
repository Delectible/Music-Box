import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A car head unit (landscape) and a phone; with SHOTS=dir tests write PNGs.
const car = Size(1280, 720);
const phone = Size(412, 892);
final shotsDir = Platform.environment['SHOTS'];

Future<void> loadFonts() async {
  final loader = FontLoader('Jost');
  for (final f in ['assets/fonts/Jost-400.ttf', 'assets/fonts/Jost-500.ttf', 'assets/fonts/Jost-600.ttf']) {
    loader.addFont(rootBundle.load(f));
  }
  await loader.load();
  final root = Platform.environment['FLUTTER_ROOT'] ?? '/tmp/flutter';
  final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final l = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await l.load();
  }
}

Size _size = car;

void setScreen(WidgetTester tester, Size size) {
  _size = size;
  tester.view.physicalSize = size * 1.5;
  tester.view.devicePixelRatio = 1.5;
  tester.view.padding = size == phone ? const FakeViewPadding(top: 72, bottom: 48) : FakeViewPadding.zero;
  addTearDown(tester.view.reset);
}

/// Writes the whole screen to SHOTS/[name].png (when SHOTS is set).
Future<void> shot(WidgetTester tester, String name) async {
  final dir = shotsDir;
  if (dir == null) return;
  final render = tester.binding.renderViews.first;
  final layer = render.debugLayer! as OffsetLayer;
  await tester.runAsync(() async {
    final image = await layer.toImage(Offset.zero & (_size * 1.5), pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}
