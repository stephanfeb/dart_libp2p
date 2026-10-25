import 'dart:async';
import 'dart:io';

/// A callback function for network interface changes
typedef NetworkInterfaceChangeCallback = void Function();

/// A function that returns a list of network interfaces
typedef NetworkInterfaceProvider = Future<List<NetworkInterface>> Function();

/// A function that returns the addresses of each network interface, keyed by
/// interface name, as address strings
typedef InterfaceAddressesProvider = Future<Map<String, Set<String>>> Function();

/// A class that monitors network interfaces for changes
class NetworkInterfaceMonitor {
  /// The interval between checks for network interface changes
  final Duration checkInterval;

  /// The function that provides the interface addresses
  final InterfaceAddressesProvider _addressesProvider;

  /// The current interface addresses, keyed by interface name
  Map<String, Set<String>> _currentAddresses = {};

  /// Timer for periodic checks
  Timer? _checkTimer;

  /// Callbacks for network interface changes
  final List<NetworkInterfaceChangeCallback> _callbacks = [];

  /// Creates a new network interface monitor.
  ///
  /// [interfaceProvider] defaults to [NetworkInterface.list].
  /// [addressesProvider] gives the addresses directly and is used instead of
  /// [interfaceProvider] when set. It does not depend on the
  /// [NetworkInterface] type, which changed in Dart 3.13 (its `addresses`
  /// became `List<InterfaceAddress>`).
  NetworkInterfaceMonitor({
    this.checkInterval = const Duration(seconds: 30),
    NetworkInterfaceProvider? interfaceProvider,
    InterfaceAddressesProvider? addressesProvider,
  }) : _addressesProvider = addressesProvider ??
            (() async => addressesOf(await (interfaceProvider ?? NetworkInterface.list)()));

  /// Returns the addresses of [interfaces], keyed by interface name.
  static Map<String, Set<String>> addressesOf(List<NetworkInterface> interfaces) => {
        for (final i in interfaces) i.name: {for (final a in i.addresses) a.address},
      };

  /// Initializes the network interface monitor
  Future<void> initialize() async {
    // Get initial network interfaces
    _currentAddresses = await _addressesProvider();

    // Start periodic checks
    _startPeriodicChecks();
  }

  /// Checks for network interface changes
  Future<bool> checkForChanges() async {
    final newAddresses = await _addressesProvider();

    // Check if interfaces have changed
    if (_interfacesHaveChanged(newAddresses)) {
      _currentAddresses = newAddresses;
      _notifyCallbacks();
      return true;
    }

    return false;
  }

  /// Adds a callback for network interface changes
  void addChangeCallback(NetworkInterfaceChangeCallback callback) {
    _callbacks.add(callback);
  }

  /// Removes a callback for network interface changes
  void removeChangeCallback(NetworkInterfaceChangeCallback callback) {
    _callbacks.remove(callback);
  }

  /// Starts periodic checks for network interface changes
  void _startPeriodicChecks() {
    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(checkInterval, (_) {
      checkForChanges();
    });
  }

  /// Stops periodic checks for network interface changes
  void stopPeriodicChecks() {
    _checkTimer?.cancel();
    _checkTimer = null;
  }

  /// Checks if network interfaces have changed: an interface was added or
  /// removed, or the addresses of an interface changed
  bool _interfacesHaveChanged(Map<String, Set<String>> newAddresses) {
    if (_currentAddresses.length != newAddresses.length) {
      return true;
    }

    for (final entry in newAddresses.entries) {
      final oldAddresses = _currentAddresses[entry.key];
      if (oldAddresses == null) {
        return true;
      }
      if (oldAddresses.length != entry.value.length || !oldAddresses.containsAll(entry.value)) {
        return true;
      }
    }

    return false;
  }

  /// Notifies callbacks of a network interface change
  void _notifyCallbacks() {
    for (final callback in _callbacks) {
      callback();
    }
  }

  /// Disposes the network interface monitor
  void dispose() {
    stopPeriodicChecks();
    _callbacks.clear();
  }
}
