import 'dart:io';
import 'package:dart_libp2p/p2p/nat/network_interface_monitor.dart';
import 'package:test/test.dart';

// The monitor gets plain addresses through addressesProvider. A mock
// NetworkInterface cannot compile on both sides of Dart 3.13, where
// NetworkInterface.addresses became List<InterfaceAddress>.
void main() {
  group('NetworkInterfaceMonitor', () {
    late NetworkInterfaceMonitor monitor;
    late Map<String, Set<String>> mockAddresses;

    setUp(() {
      // Initial mock interfaces
      mockAddresses = {
        'eth0': {'192.168.1.1'},
      };

      // Create monitor with mock addresses provider
      monitor = NetworkInterfaceMonitor(
        checkInterval: Duration(milliseconds: 100), // Short interval for testing
        addressesProvider: () async => mockAddresses,
      );
    });

    tearDown(() {
      monitor.dispose();
    });

    test('should detect changes in network interfaces', () async {
      // Initialize the monitor with initial interfaces
      await monitor.initialize();

      // Change the mock interfaces
      mockAddresses = {
        'eth0': {'192.168.1.2'}, // Changed address
      };

      // Check for changes
      final hasChanged = await monitor.checkForChanges();

      // Verify that changes were detected
      expect(hasChanged, isTrue);
    });

    test('should notify callbacks when network interfaces change', () async {
      // Initialize the monitor with initial interfaces
      await monitor.initialize();

      // Set up callback
      var callbackCalled = false;
      monitor.addChangeCallback(() {
        callbackCalled = true;
      });

      // Change the mock interfaces
      mockAddresses = {
        'eth0': {'192.168.1.2'}, // Changed address
      };

      // Check for changes
      await monitor.checkForChanges();

      // Verify that callback was called
      expect(callbackCalled, isTrue);
    });

    test('should not notify callbacks when network interfaces do not change', () async {
      // Initialize the monitor with initial interfaces
      await monitor.initialize();

      // Set up callback
      var callbackCalled = false;
      monitor.addChangeCallback(() {
        callbackCalled = true;
      });

      // Don't change the mock interfaces

      // Check for changes (with the same interfaces)
      await monitor.checkForChanges();

      // Verify that callback was not called
      expect(callbackCalled, isFalse);
    });

    test('should detect changes in network interface count', () async {
      // Initialize the monitor with initial interfaces
      await monitor.initialize();

      // Change the mock interfaces to add an interface
      mockAddresses = {
        'eth0': {'192.168.1.1'},
        'wlan0': {'10.0.0.1'},
      };

      // Check for changes
      final hasChanged = await monitor.checkForChanges();

      // Verify that changes were detected
      expect(hasChanged, isTrue);
    });

    test('addressesOf keys the addresses of real interfaces by name', () async {
      final interfaces = await NetworkInterface.list();

      final addresses = NetworkInterfaceMonitor.addressesOf(interfaces);

      expect(addresses.keys, unorderedEquals(interfaces.map((i) => i.name).toSet()));
      for (final i in interfaces) {
        expect(addresses[i.name], containsAll(i.addresses.map((a) => a.address)));
      }
    });
  });
}
