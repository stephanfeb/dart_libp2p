# The Event Bus

The `EventBus` provides a powerful, type-based system for subscribing to and emitting events within the libp2p host. It allows different components of the system to communicate with each other and with your application in a decoupled way.

Every `Host` has an `EventBus` instance, accessible via `host.eventBus`.

## Key Concepts

-   **Events**: Events are simply Dart objects. Any object can be an event. The event's type is used to route it to the correct subscribers.
-   **Emitter**: An `Emitter` is used to send events onto the bus.
-   **Subscription**: A `Subscription` is used to listen for events of a specific type (or types). It provides a `Stream` that you can listen to.

## Subscribing to Events

You can subscribe to events to react to things happening within the libp2p stack. The `subscribe` method returns a `Subscription` object, which contains a `Stream` of events.

### Example: Subscribing to Connection Events

The library defines several core event types. For example, `EvtPeerConnectednessChanged` is emitted when the host gets its first connection to a peer (`Connectedness.connected`) and when the last connection to that peer closes (`Connectedness.notConnected`).

```dart
import 'package:dart_libp2p/dart_libp2p.dart'; // EventBus and the core event types

// Assuming 'host' is your started Host
final EventBus bus = host.eventBus;

// Subscribe to connectedness changes and completed Identify exchanges
final sub = bus.subscribe([EvtPeerConnectednessChanged, EvtPeerIdentificationCompleted]);

sub.stream.listen((event) {
  if (event is EvtPeerConnectednessChanged) {
    if (event.connectedness == Connectedness.connected) {
      print('Peer connected: ${event.peer}');
    } else if (event.connectedness == Connectedness.notConnected) {
      print('Peer disconnected: ${event.peer}');
    }
  } else if (event is EvtPeerIdentificationCompleted) {
    print('Peer ${event.peer} speaks ${event.protocols}');
  }
});

// When you're done, close the subscription to release resources
// await sub.close();
```

`subscribe` returns at once. A new subscriber also receives the last event already emitted of each type it subscribes to. For a callback on every connection rather than every peer, use `host.network.notify(...)` with a `NotifyBundle`.

### Subscribing to All Events

You can subscribe to all events on the bus using the `WildcardSubscription` type.

```dart
final sub = bus.subscribe(WildcardSubscription);
sub.stream.listen((event) {
  print('Received event of type ${event.runtimeType}: $event');
});
```

## Emitting Events

While the libp2p stack emits many useful events, you can also use the event bus to emit your own custom events for your application's internal communication.

### Example: Emitting a Custom Event

1.  **Define your event class:**

    ```dart
    class MyCustomEvent {
      final String message;
      MyCustomEvent(this.message);
    }
    ```

2.  **Create an emitter and emit the event:**

    ```dart
    // Create an emitter for your event type
    final emitter = await bus.emitter(MyCustomEvent);

    // Emit an instance of your event
    await emitter.emit(MyCustomEvent('Hello, Event Bus!'));

    // Close the emitter when you are done with it
    await emitter.close();
    ```

3.  **Subscribe to your custom event elsewhere in your application:**

    ```dart
    final sub = bus.subscribe(MyCustomEvent);
    sub.stream.listen((event) {
      // event is guaranteed to be of type MyCustomEvent
      print('Handled custom event: ${event.message}');
    });
    ```

## Core Event Types

Here are the core event types you can subscribe to. They are exported by `package:dart_libp2p/dart_libp2p.dart`.

| Event | Defined in | Emitted when |
|---|---|---|
| `EvtPeerConnectednessChanged` | `core/network/network.dart` | The host gets its first connection to a peer, or loses its last one (`peer`, `connectedness`). |
| `EvtPeerIdentificationCompleted` | `core/event/identify.dart` | The `Identify` protocol has completed with a peer (`peer`, `conn`, `listenAddrs`, `protocols`, `agentVersion`, `observedAddr`, ...). |
| `EvtPeerIdentificationFailed` | `core/event/identify.dart` | `Identify` with a peer failed (`peer`, `reason`). |
| `EvtPeerProtocolsUpdated` | `core/event/protocol.dart` | A peer's supported protocols have changed (`peer`, `added`, `removed`). |
| `EvtLocalProtocolsUpdated` | `core/event/protocol.dart` | A stream handler was added to or removed from this host (`added`, `removed`). |
| `EvtLocalAddressesUpdated` | `core/event/addrs.dart` | This host's advertised addresses have changed (`current`, `removed`). |
| `EvtLocalReachabilityChanged` | `core/event/reachability.dart` | AutoNAT (or `Libp2p.forceReachability`) has set this host's reachability (`reachability`). |
| `EvtNATDeviceTypeChanged` | `core/event/nattype.dart` | The NAT type behind this host has been detected. |
| `EvtAutoRelayAddrsUpdated` | `p2p/host/autorelay/autorelay.dart` (not in the barrel) | AutoRelay has new relay (`/p2p-circuit`) addresses to advertise (`advertisableAddrs`). |
