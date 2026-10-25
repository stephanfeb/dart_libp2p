
/// The support status for the identify push protocol.
enum IdentifyPushSupport {
  /// The peer's support for identify push is unknown.
  unknown,
  
  /// The peer supports identify push.
  supported,
  
  /// The peer does not support identify push.
  unsupported,
}

/// MetricsTracer is an interface for collecting metrics from the identify service.
abstract class MetricsTracer {
  /// TriggeredPushes counts IdentifyPushes triggered by event.
  void triggeredPushes(dynamic event);
  
  /// ConnPushSupport counts peers by Push Support.
  void connPushSupport(IdentifyPushSupport support);
  
  /// IdentifyReceived tracks metrics on receiving an identify response.
  void identifyReceived(bool isPush, int numProtocols, int numAddrs);
  
  /// IdentifySent tracks metrics on sending an identify response.
  void identifySent(bool isPush, int numProtocols, int numAddrs);
}

/// A no-op implementation of MetricsTracer that doesn't collect any metrics.
class NoopMetricsTracer implements MetricsTracer {
  /// Creates a new no-op metrics tracer.
  const NoopMetricsTracer();
  
  @override
  void triggeredPushes(dynamic event) {}
  
  @override
  void connPushSupport(IdentifyPushSupport support) {}
  
  @override
  void identifyReceived(bool isPush, int numProtocols, int numAddrs) {}
  
  @override
  void identifySent(bool isPush, int numProtocols, int numAddrs) {}
}

/// A metrics tracer that records nothing yet. Its methods are empty.
class LoggingMetricsTracer implements MetricsTracer {
  /// Creates a new logging metrics tracer.
  const LoggingMetricsTracer();
  
  @override
  void triggeredPushes(dynamic event) {}
  
  @override
  void connPushSupport(IdentifyPushSupport support) {}
  
  @override
  void identifyReceived(bool isPush, int numProtocols, int numAddrs) {}
  
  @override
  void identifySent(bool isPush, int numProtocols, int numAddrs) {}
}
