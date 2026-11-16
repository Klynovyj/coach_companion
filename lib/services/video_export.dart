import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Nativer MP4-Encoder (Android, MediaCodec H.264): nimmt einzelne Frames als
/// RGBA (wie `ui.ImageByteFormat.rawRgba`) und schreibt ein Video für
/// Instagram/WhatsApp. Optional liegt ein Video (KI-Video) als bewegter
/// Hintergrund darunter.
class VideoEncoder {
  static const _ch = MethodChannel('coach_companion/video');

  /// Video-Export gibt es nur in der Android-App.
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static Future<bool> start({
    required String path,
    required int width,
    required int height,
    int fps = 30,
    int bitrate = 8000000,
    String? bgVideo,
  }) async {
    final ok = await _ch.invokeMethod<bool>('start', {
      'path': path,
      'width': width,
      'height': height,
      'fps': fps,
      'bitrate': bitrate,
      'bgVideo': bgVideo,
    });
    return ok == true;
  }

  static Future<void> frame(Uint8List rgba, int index) =>
      _ch.invokeMethod<void>('frame', {'rgba': rgba, 'index': index});

  static Future<String?> finish() => _ch.invokeMethod<String>('finish');

  static Future<void> cancel() async {
    try {
      await _ch.invokeMethod<void>('cancel');
    } catch (_) {}
  }
}
