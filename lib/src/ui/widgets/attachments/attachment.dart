// Images attached to the message being written, and how they end up in the
// prompt. No widgets and no platform channels in here.

import 'package:flutter/foundation.dart';

import '../../annotate/annotation_model.dart';

/// Most images per message.
const kMaxAttachments = 6;

class Attachment {
  Attachment({
    required this.id,
    required this.original,
    required this.extension,
  });

  final int id;

  /// Bytes as picked (never modified: the editor always reopens on these).
  final Uint8List original;

  /// Extension of [original], without the dot (`jpg`, `png`...).
  final String extension;

  /// Marks, kept to reopen the editor.
  AnnotationModel? model;

  /// Original with the marks flattened (PNG), when it was edited.
  Uint8List? annotated;

  /// Remote path once uploaded; reset when the image is edited again.
  String? remotePath;

  bool get edited => annotated != null;
  Uint8List get sendBytes => annotated ?? original;
  String get sendExtension => annotated != null ? 'png' : extension;
}

/// The attachments of the composer.
class AttachmentsController extends ChangeNotifier {
  final List<Attachment> _items = [];
  int _nextId = 1;

  List<Attachment> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  int get length => _items.length;
  int get remaining => kMaxAttachments - _items.length;

  /// Adds as many as fit; returns how many were added.
  int addAll(Iterable<({Uint8List bytes, String extension})> images) {
    var added = 0;
    for (final i in images) {
      if (_items.length >= kMaxAttachments) break;
      _items.add(
        Attachment(id: _nextId++, original: i.bytes, extension: i.extension),
      );
      added++;
    }
    if (added > 0) notifyListeners();
    return added;
  }

  void remove(int id) {
    _items.removeWhere((a) => a.id == id);
    notifyListeners();
  }

  /// Stores the editor's result; an empty model means "no marks".
  void setEdit(int id, AnnotationModel model, Uint8List png) {
    final a = _items.where((a) => a.id == id).firstOrNull;
    if (a == null) return;
    a.model = model;
    a.annotated = model.isEmpty ? null : png;
    a.remotePath = null;
    notifyListeners();
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }
}

/// The prompt typed into the agent: [text], then a blank line and one
/// absolute path per line (harnesses pick up image paths in a prompt). With
/// no text the prompt is only the paths.
String composePrompt(String text, List<String> paths) {
  final t = text.trim();
  if (paths.isEmpty) return t;
  final list = paths.join('\n');
  return t.isEmpty ? list : '$t\n\n$list';
}
