import 'dart:io';
import 'dart:typed_data';
import 'conn.dart';
import 'rcmgr.dart' show ConnManagementScope, ResourceManager, ResourceScopeSpan;

/// TransportConn extends the Conn interface with methods for reading and writing raw data.
/// This is used by transport implementations that need to send and receive data directly.
abstract class TransportConn extends Conn {
  /// Reads data from the connection.
  /// If [length] is provided, reads exactly that many bytes.
  /// Otherwise, reads whatever is available.
  Future<Uint8List> read([int? length]);

  Socket get socket ;

  /// Writes data to the connection.
  Future<void> write(Uint8List data);

  /// Sets a timeout for read operations.
  void setReadTimeout(Duration timeout);

  /// Sets a timeout for write operations.
  void setWriteTimeout(Duration timeout);

  /// Notifies that activity has occurred on this transport connection,
  /// potentially due to activity on a multiplexed stream over it.
  /// This can be used by multiplexers to inform the connection manager.
  void notifyActivity();
}

/// A [TransportConn] whose transport opened its resource scope, as go-libp2p
/// transports do with `ResourceManager.OpenConnection`.
///
/// The scope covers the connection from the moment the transport makes it
/// (in the transient scope, during the upgrade). The swarm uses this scope
/// for the connection when [resourceManager] is the swarm's own resource
/// manager, and moves it to the peer's scope with
/// [ConnManagementScope.setPeer] once the peer is known. The connection is
/// then counted once. Calling [ResourceScopeSpan.done] more than once on
/// [managementScope] is allowed: the scope is released once.
abstract class ScopedTransportConn implements TransportConn {
  /// The resource manager that opened [managementScope].
  ResourceManager get resourceManager;

  /// The connection's scope, or null if it was not opened (or has failed).
  ConnManagementScope? get managementScope;
}
