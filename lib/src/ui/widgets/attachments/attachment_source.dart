// Where attachments come from: gallery and camera through image_picker,
// behind an interface so tests never touch platform channels.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

typedef PickedImage = ({Uint8List bytes, String extension});

abstract class AttachmentSource {
  /// Up to [limit] images from the gallery (empty when cancelled).
  Future<List<PickedImage>> gallery({required int limit});

  /// One photo from the camera (null when cancelled).
  Future<PickedImage?> camera();
}

/// Uploads stay small: pictures are scaled to 2048 px and compressed (JPEG).
class PlatformImageSource implements AttachmentSource {
  PlatformImageSource([ImagePicker? picker])
    : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;

  static const _max = 2048.0;
  static const _quality = 85;

  @override
  Future<List<PickedImage>> gallery({required int limit}) async {
    final files = await _picker.pickMultiImage(
      maxWidth: _max,
      maxHeight: _max,
      imageQuality: _quality,
      limit: limit >= 2 ? limit : null,
    );
    return [for (final f in files.take(limit)) await _read(f)];
  }

  @override
  Future<PickedImage?> camera() async {
    final f = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: _max,
      maxHeight: _max,
      imageQuality: _quality,
    );
    return f == null ? null : _read(f);
  }

  Future<PickedImage> _read(XFile f) async => (
    bytes: await f.readAsBytes(),
    extension: extensionOf(f.name.isNotEmpty ? f.name : f.path),
  );
}

/// Lower-case extension of a file name or path, `jpg` when unknown.
String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return 'jpg';
  final e = name.substring(dot + 1).toLowerCase();
  if (!RegExp(r'^[a-z0-9]{1,5}$').hasMatch(e)) return 'jpg';
  return e == 'jpeg' ? 'jpg' : e;
}

final attachmentSourceProvider = Provider<AttachmentSource>(
  (ref) => PlatformImageSource(),
);
