const sessionHandoffReconnectWindowSeconds = 45;

bool isTransientInstalledServerHandoffError(
    String type, String title, String text) {
  if (type != 'error' || title != 'Connection Error') {
    return false;
  }
  return text == 'Remote desktop is offline' ||
      text == 'Failed to connect to rendezvous server' ||
      text == 'Failed to connect via rendezvous server' ||
      text == 'Rendezvous connection is reset by the peer' ||
      text == 'Reset by the peer';
}
