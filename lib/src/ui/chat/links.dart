// URL extraction for chat text and the injectable external launcher.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' as ul;

/// A http(s) URL found in a text: [start]..[end] (end exclusive) in the text.
class UrlMatch {
  const UrlMatch(this.start, this.end, this.url);
  final int start;
  final int end;
  final String url;

  @override
  bool operator ==(Object other) =>
      other is UrlMatch &&
      other.start == start &&
      other.end == end &&
      other.url == url;

  @override
  int get hashCode => Object.hash(start, end, url);

  @override
  String toString() => 'UrlMatch($start, $end, $url)';
}

final _urlRe = RegExp(r'https?://[^\s<>`]+', caseSensitive: false);
const _trailing = '.,;:!?\'"';
const _closers = {')': '(', ']': '[', '}': '{'};

int _count(String s, String c) => c.allMatches(s).length;

/// Finds http(s) URLs, trimming trailing punctuation (and closing brackets
/// that have no opener inside the URL).
List<UrlMatch> findUrls(String text) {
  final out = <UrlMatch>[];
  for (final m in _urlRe.allMatches(text)) {
    var url = m.group(0)!;
    while (url.isNotEmpty) {
      final last = url[url.length - 1];
      if (_trailing.contains(last)) {
        url = url.substring(0, url.length - 1);
      } else if (_closers.containsKey(last) &&
          _count(url, last) > _count(url, _closers[last]!)) {
        url = url.substring(0, url.length - 1);
      } else {
        break;
      }
    }
    // Needs something after the scheme.
    if (RegExp(r'^https?://[^/?#]+', caseSensitive: false).hasMatch(url)) {
      out.add(UrlMatch(m.start, m.start + url.length, url));
    }
  }
  return out;
}

typedef UrlLauncher = Future<bool> Function(Uri uri);

Future<bool> _launchExternal(Uri uri) =>
    ul.launchUrl(uri, mode: ul.LaunchMode.externalApplication);

/// Opens a URL in the external browser; overridden in tests.
final urlLauncherProvider = Provider<UrlLauncher>((ref) => _launchExternal);
