import 'package:flutter_hbb/common/peer_search.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_test/flutter_test.dart';

Peer _peer({
  required String id,
  String alias = '',
  String hostname = '',
  String username = '',
  String note = '',
}) =>
    Peer(
      id: id,
      hash: '',
      password: '',
      username: username,
      hostname: hostname,
      platform: 'Windows',
      alias: alias,
      tags: [],
      forceAlwaysRelay: false,
      rdpPort: '',
      rdpUsername: '',
      loginName: '',
      device_group_name: '',
      note: note,
    );

void main() {
  group('normalizeSearchText', () {
    test('normalizes Cyrillic and Latin case to the same value', () {
      expect(normalizeSearchText('сервер'), 'server');
      expect(normalizeSearchText('СЕРВЕР'), 'server');
      expect(normalizeSearchText('server'), 'server');
      expect(normalizeSearchText('SERVER'), 'server');
    });

    test('preserves digits and separators', () {
      expect(normalizeSearchText('склад-01'), 'sklad-01');
      expect(normalizeSearchText('СКЛАД-01'), 'sklad-01');
      expect(normalizeSearchText('SKLAD-01'), 'sklad-01');
      expect(normalizeSearchText('PC-Иванов'), 'pc-ivanov');
      expect(normalizeSearchText('PC-IVANOV'), 'pc-ivanov');
      expect(
        normalizeSearchText(' SERVER-Склад_01.бух '),
        'server-sklad_01.bukh',
      );
    });

    test('supports the full Russian alphabet deterministically', () {
      expect(
        normalizeSearchText('АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ'),
        'abvgdeezhziyklmnoprstufkhtschshshchyeyuya',
      );
    });
  });

  group('peerMatchesSearch', () {
    test('matches Cyrillic and Latin spellings in both directions', () {
      final cases = <(String, String)>[
        ('СЕРВЕР-01', 'server'),
        ('SERVER-01', 'сервер'),
        ('СКЛАД-05', 'sklad'),
        ('SKLAD-05', 'склад'),
        ('PC-Иванов', 'ivanov'),
        ('PC-IVANOV', 'иванов'),
      ];

      for (final (name, query) in cases) {
        expect(
          peerMatchesSearch(
            _peer(id: '123456789', alias: name),
            PeerSearchQuery(query),
          ),
          isTrue,
          reason: '$name should match $query',
        );
      }
    });

    test('keeps unrelated names out of the result', () {
      expect(
        peerMatchesSearch(
          _peer(id: '123456789', alias: 'SERVER-01'),
          PeerSearchQuery('sklad'),
        ),
        isFalse,
      );
      expect(
        peerMatchesSearch(
          _peer(id: '123456789', alias: 'СКЛАД-01'),
          PeerSearchQuery('server'),
        ),
        isFalse,
      );
    });

    test('matches formatted and unformatted real IDs independently', () {
      final peer = _peer(
        id: '506396644',
        alias: 'LuxeFit-Ноут продавца',
      );

      expect(normalizePeerIdForSearch(' АБ 123 '), 'аб123');
      expect(peerMatchesSearch(peer, PeerSearchQuery('LuxeFit')), isTrue);
      expect(peerMatchesSearch(peer, PeerSearchQuery('luxe')), isTrue);
      expect(peerMatchesSearch(peer, PeerSearchQuery('506 396 644')), isTrue);
      expect(peerMatchesSearch(peer, PeerSearchQuery('506396644')), isTrue);
      expect(peer.id, '506396644');
      expect(peer.alias, 'LuxeFit-Ноут продавца');
    });

    test('returns the same acceptance set for either alphabet', () {
      final peers = [
        _peer(id: '1', alias: 'SERVER-01'),
        _peer(id: '2', alias: 'СЕРВЕР-02'),
        _peer(id: '3', alias: 'SKLAD-01'),
        _peer(id: '4', alias: 'СКЛАД-02'),
      ];

      List<String> idsFor(String query) => peers
          .where((peer) => peerMatchesSearch(peer, PeerSearchQuery(query)))
          .map((peer) => peer.id)
          .toList();

      expect(idsFor('server'), ['1', '2']);
      expect(idsFor('сервер'), ['1', '2']);
      expect(idsFor('sklad'), ['3', '4']);
      expect(idsFor('склад'), ['3', '4']);
    });

    test('preserves note matching only when the tab enables it', () {
      final peer = _peer(id: '123456789', note: 'Складской терминал');

      expect(peerMatchesSearch(peer, PeerSearchQuery('sklad')), isFalse);
      expect(
        peerMatchesSearch(
          peer,
          PeerSearchQuery('sklad'),
          includeNote: true,
        ),
        isTrue,
      );
    });
  });
}
