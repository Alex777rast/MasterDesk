import '../models/peer_model.dart';

const Map<int, String> _russianCyrillicToLatin = {
  0x0430: 'a',
  0x0431: 'b',
  0x0432: 'v',
  0x0433: 'g',
  0x0434: 'd',
  0x0435: 'e',
  0x0451: 'e',
  0x0436: 'zh',
  0x0437: 'z',
  0x0438: 'i',
  0x0439: 'y',
  0x043a: 'k',
  0x043b: 'l',
  0x043c: 'm',
  0x043d: 'n',
  0x043e: 'o',
  0x043f: 'p',
  0x0440: 'r',
  0x0441: 's',
  0x0442: 't',
  0x0443: 'u',
  0x0444: 'f',
  0x0445: 'kh',
  0x0446: 'ts',
  0x0447: 'ch',
  0x0448: 'sh',
  0x0449: 'shch',
  0x044a: '',
  0x044b: 'y',
  0x044c: '',
  0x044d: 'e',
  0x044e: 'yu',
  0x044f: 'ya',
};

/// Converts peer names and search input to the same lowercase Latin form.
///
/// Separators, digits, Latin text, and non-Russian characters are preserved.
String normalizeSearchText(String value) {
  final normalized = value.trim().toLowerCase();
  final result = StringBuffer();
  for (final rune in normalized.runes) {
    result.write(_russianCyrillicToLatin[rune] ?? String.fromCharCode(rune));
  }
  return result.toString();
}

bool _isIdWhitespace(int rune) =>
    rune == 0x0009 ||
    rune == 0x000a ||
    rune == 0x000b ||
    rune == 0x000c ||
    rune == 0x000d ||
    rune == 0x0020 ||
    rune == 0x0085 ||
    rune == 0x00a0 ||
    rune == 0x1680 ||
    (rune >= 0x2000 && rune <= 0x200a) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    rune == 0x202f ||
    rune == 0x205f ||
    rune == 0x3000;

/// Normalizes only visual whitespace in an ID, without transliteration.
String normalizePeerIdForSearch(String value) {
  final result = StringBuffer();
  for (final rune in value.trim().toLowerCase().runes) {
    if (!_isIdWhitespace(rune)) {
      result.writeCharCode(rune);
    }
  }
  return result.toString();
}

class PeerSearchQuery {
  final String text;
  final String id;

  PeerSearchQuery(String value)
      : text = normalizeSearchText(value),
        id = normalizePeerIdForSearch(value);

  bool get isEmpty => text.isEmpty && id.isEmpty;
}

bool peerMatchesSearch(
  Peer peer,
  PeerSearchQuery query, {
  bool includeNote = false,
}) {
  if (query.isEmpty) {
    return true;
  }

  if (query.id.isNotEmpty &&
      normalizePeerIdForSearch(peer.id).contains(query.id)) {
    return true;
  }

  if (query.text.isNotEmpty) {
    if (normalizeSearchText(peer.id).contains(query.text) ||
        normalizeSearchText(peer.hostname).contains(query.text) ||
        normalizeSearchText(peer.username).contains(query.text) ||
        normalizeSearchText(peer.alias).contains(query.text)) {
      return true;
    }
    if (includeNote && normalizeSearchText(peer.note).contains(query.text)) {
      return true;
    }
  }

  return false;
}
