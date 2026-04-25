import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:test/test.dart';

void main() {
  test('parses long base58 identity peer IDs', () {
    const peerId =
        '22ecpdjAT14xkGFQXYx9YT3x4yrJBwM85a9nFX9gEzsseWeKdSLnU8Xs5ZQQzKTXpPvZqjWx7VsGXNrFFJb2K2qVRJq4vTQPFU2YUbEXrdTeksNPHadGXtGuWKomYZU1LmcnimCaAiat18npsQeHgunHjzEkQaiuxSxmX7he1zS3pJY2xK17eXSbneQWVSXCgs4YaZ9iN2hWHu3h5taq4PCSJHaefUyeEBv6dFC7tukaRT2PD77njXVNMfid9dRiqePN76hz3JgZkD4BFdMGmtaX3mUhDY58186fXum82JW63Ve6Tet1xzvHKMCLWbwHattwD55W1PWoTLWtZKBQniqZSMChGQKX9pty45CZiUBN83xd8t34k9voS6yv';

    final parsed = PeerId.fromString(peerId);

    expect(parsed.toString(), peerId);
  });
}
