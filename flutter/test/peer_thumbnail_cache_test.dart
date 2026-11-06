import 'package:flutter_hbb/common/peer_thumbnail_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('peer thumbnail key is deterministic and filename-safe', () {
    final key = peerThumbnailIdKey(r'peer:/\name');

    expect(key, isNotEmpty);
    expect(key, isNot(contains('/')));
    expect(key, isNot(contains(r'\')));
    expect(peerThumbnailIdKey(r'peer:/\name'), key);
  });

  test('peer thumbnail filename validation rejects traversal and other peers',
      () {
    const peerId = '123 456 789';
    final valid = '${peerThumbnailIdKey(peerId)}-1700000000000000.png';

    expect(isValidPeerThumbnailFileName(peerId, valid), isTrue);
    expect(isValidPeerThumbnailFileName(peerId, '../$valid'), isFalse);
    expect(isValidPeerThumbnailFileName('other-peer', valid), isFalse);
    expect(isValidPeerThumbnailFileName(peerId, '$valid.tmp'), isFalse);
  });
}
