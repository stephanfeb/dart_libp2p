import 'package:dart_libp2p/core/host/host.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/context.dart';
import 'package:dart_libp2p/core/network/network.dart';
import 'package:dart_libp2p/core/network/notifiee.dart';
import 'package:dart_libp2p/core/network/rcmgr.dart';
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/core/peerstore.dart';
import 'package:dart_libp2p/core/protocol/protocol.dart';
import 'package:dart_libp2p/core/protocol/switch.dart';
import 'package:dart_libp2p/core/routing/routing.dart';
import 'package:dart_libp2p/core/connmgr/conn_manager.dart';
import 'package:dart_libp2p/core/event/bus.dart';
import 'package:dart_libp2p/p2p/protocol/holepunch.dart'; // Added for HolePunchService

class MockHost implements Host {

  @override
  Future<void> close() {
    // TODO: implement close
    throw UnimplementedError();
  }

  @override
  Future<void> connect(AddrInfo pi, {Context? context}) {
    // TODO: implement connect
    throw UnimplementedError();
  }

  Connectedness connectedness(PeerId peerId) {
    // TODO: implement connectedness
    throw UnimplementedError();
  }

  List<Conn> get conns {
    // TODO: implement conns
    throw UnimplementedError();
  }

  List<Conn> connsToPeer(PeerId peerId) {
    // TODO: implement connsToPeer
    throw UnimplementedError();
  }

  @override
  Future<P2PStream> newStream(PeerId p, List<ProtocolID> pids, Context context) {
    // TODO: implement newStream
    throw UnimplementedError();
  }

  Future<void> listen(List<MultiAddr> addrs) {
    // TODO: implement listen
    throw UnimplementedError();
  }

  Future<List<MultiAddr>> get interfaceListenAddresses {
    // TODO: implement interfaceListenAddresses
    throw UnimplementedError();
  }

  @override
  PeerId get id {
    // TODO: implement id
    throw UnimplementedError();
  }

  @override
  ProtocolSwitch get mux {
    // TODO: implement mux
    throw UnimplementedError();
  }

  @override
  Network get network {
    // TODO: implement network
    throw UnimplementedError();
  }

  void notify(Notifiee notifiee) {
    // TODO: implement notify
  }

  List<PeerId> get peers {
    // TODO: implement peers
    throw UnimplementedError();
  }

  @override
  Peerstore get peerStore {
    // TODO: implement peerStore
    throw UnimplementedError();
  }

  Future<void> removeProtocol(String protocolId) {
    // TODO: implement removeProtocol
    throw UnimplementedError();
  }

  ResourceManager get resourceManager {
    // TODO: implement resourceManager
    throw UnimplementedError();
  }

  Routing get routing {
    // TODO: implement routing
    throw UnimplementedError();
  }

  @override
  void setStreamHandler(ProtocolID pid, StreamHandler handler) {
    // TODO: implement setStreamHandler
  }

  @override
  void setStreamHandlerMatch(ProtocolID pid, bool Function(ProtocolID p1) match, StreamHandler handler) {
    // TODO: implement setStreamHandlerMatch
    throw UnimplementedError();
  }

  void stopNotify(Notifiee notifiee) {
    // TODO: implement stopNotify
  }

  bool canDial(PeerId peerId, MultiAddr addr) {
    // TODO: implement canDial
    throw UnimplementedError();
  }

  Future<void> closePeer(PeerId peerId) {
    // TODO: implement closePeer
    throw UnimplementedError();
  }

  Future<List<MultiAddr>> getListenAddrs() {
    // TODO: implement getListenAddrs
    throw UnimplementedError();
  }

  @override
  Future<void> start() {
    // TODO: implement start
    throw UnimplementedError();
  }

  @override
  ConnManager get connManager {
    // TODO: implement connManager
    throw UnimplementedError();
  }

  @override
  EventBus get eventBus {
    // TODO: implement eventBus
    throw UnimplementedError();
  }

  @override
  List<MultiAddr> get addrs {
    // TODO: implement addrs
    throw UnimplementedError();
  }

  void removeStreamHandlerMatch(ProtocolID pid) {
    // TODO: implement removeStreamHandlerMatch
    throw UnimplementedError();
  }

  @override
  void removeStreamHandler(ProtocolID pid) {
    // TODO: implement removeStreamHandler
    throw UnimplementedError();
  }

  @override
  HolePunchService? get holePunchService => null; // Added stub for HolePunchService
}
