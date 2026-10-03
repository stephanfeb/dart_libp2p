import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:test/test.dart';

void main() {
  const rawIdentityPeerId =
      '22ecpdjAT14xkGFQXYx9YT3x4yrJBwM85a9nFX9gEzsseWeKdSLnU8Xs5ZQQzKTXpPvZqjWx7VsGXNrFFJb2K2qVRJq4vTQPFU2YUbEXrdTeksNPHadGXtGuWKomYZU1LmcnimCaAiat18npsQeHgunHjzEkQaiuxSxmX7he1zS3pJY2xK17eXSbneQWVSXCgs4YaZ9iN2hWHu3h5taq4PCSJHaefUyeEBv6dFC7tukaRT2PD77njXVNMfid9dRiqePN76hz3JgZkD4BFdMGmtaX3mUhDY58186fXum82JW63Ve6Tet1xzvHKMCLWbwHattwD55W1PWoTLWtZKBQniqZSMChGQKX9pty45CZiUBN83xd8t34k9voS6yv';

  test('parses and round-trips a raw base58 identity multihash', () {
    final peerId = PeerId.fromString(rawIdentityPeerId);

    expect(peerId.toBase58(), rawIdentityPeerId);
    expect(PeerId.decode(peerId.toBase58()), peerId);
  });

  test('continues to parse legacy RSA sha2-256 PeerIds', () {
    const rsaPeerId = 'QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN';

    expect(PeerId.fromString(rsaPeerId).toBase58(), rsaPeerId);
  });

  test('rejects base58 data that is not a multihash', () {
    expect(() => PeerId.fromString('23456789ABCDEFGH'), throwsFormatException);
  });
}
