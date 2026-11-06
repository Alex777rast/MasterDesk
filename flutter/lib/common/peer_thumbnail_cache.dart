import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

const peerThumbnailOptionKey = 'peer-thumbnail-file';

class PeerThumbnailCapture {
  final String fileName;
  final String path;
  final String previousFileName;

  const PeerThumbnailCapture({
    required this.fileName,
    required this.path,
    required this.previousFileName,
  });
}

String peerThumbnailIdKey(String peerId) =>
    base64Url.encode(utf8.encode(peerId)).replaceAll('=', '');

bool isValidPeerThumbnailFileName(String peerId, String fileName) {
  if (fileName.isEmpty || path.basename(fileName) != fileName) return false;
  final prefix = '${peerThumbnailIdKey(peerId)}-';
  return fileName.startsWith(prefix) && fileName.endsWith('.png');
}

Future<Directory> _peerThumbnailDirectory({required bool create}) async {
  final support = await getApplicationSupportDirectory();
  final directory = Directory(path.join(support.path, 'peer-thumbnails'));
  if (create && !await directory.exists()) {
    await directory.create(recursive: true);
  }
  return directory;
}

Future<PeerThumbnailCapture> createPeerThumbnailCapture(
  String peerId,
  String previousFileName,
) async {
  final directory = await _peerThumbnailDirectory(create: true);
  final fileName =
      '${peerThumbnailIdKey(peerId)}-${DateTime.now().microsecondsSinceEpoch}.png';
  return PeerThumbnailCapture(
    fileName: fileName,
    path: path.join(directory.path, fileName),
    previousFileName: previousFileName,
  );
}

Future<String?> resolvePeerThumbnailPath(
  String peerId,
  String fileName,
) async {
  if (!isValidPeerThumbnailFileName(peerId, fileName)) return null;
  final directory = await _peerThumbnailDirectory(create: false);
  return path.join(directory.path, fileName);
}

Future<void> deletePeerThumbnail(
  String peerId,
  String fileName,
) async {
  final thumbnailPath = await resolvePeerThumbnailPath(peerId, fileName);
  if (thumbnailPath == null) return;
  final file = File(thumbnailPath);
  if (await file.exists()) {
    await file.delete();
  }
}
