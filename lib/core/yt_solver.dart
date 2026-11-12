// The solver base classes aren't exported by the package; this is the hook
// it provides for custom JavaScript engines.
// ignore_for_file: implementation_imports
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/ejs/base_ejs_solver.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/ejs/ejs.dart';

/// Solves YouTube's stream challenges (yt-dlp's solver, fetched from its
/// GitHub releases and checked against a known hash) in Android's WebView,
/// so the browser-type YouTube clients can be used.
class WebViewSolver extends BaseEJSSolver {
  static const _ch = MethodChannel('roadie/library');
  Future<void>? _ready;

  Future<void> _init() => _ready ??= () async {
    final script = await EJSBuilder.getJSModules();
    final ok = await _ch.invokeMethod<bool>('jsInit', {'script': script});
    if (ok != true) {
      _ready = null;
      throw Exception('The YouTube solver didn\'t start');
    }
  }();

  @override
  Future<String> executeJavaScript(String jsCode) async {
    await _init();
    final out = await _ch.invokeMethod<String>('jsEval', {'code': jsCode});
    if (out == null) throw Exception('The YouTube solver returned nothing');
    return out;
  }
}
