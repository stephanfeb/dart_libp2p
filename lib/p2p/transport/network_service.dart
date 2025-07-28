// First, ensure you have the required permissions in AndroidManifest.xml
// Add these inside the <manifest> tag:
// <uses-permission android:name="android.permission.INTERNET"/>
// <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>

import 'dart:io';
import 'dart:typed_data';

class NetworkService {
  // TCP Socket Implementation
  Socket? _tcpSocket;
  bool _isConnected = false;
  
  Future<void> createTcpServer(String host, int port) async {
    try {
      final server = await ServerSocket.bind(host, port);
      print('TCP Server listening on ${server.address}:${server.port}');
      
      server.listen((Socket client) {
        handleClient(client);
      });
    } catch (e) {
      print('Error creating TCP server: $e');
    }
  }

  Future<void> connectToTcpServer(String host, int port) async {
    try {
      _tcpSocket = await Socket.connect(host, port);
      _isConnected = true;
      print('Connected to server at ${_tcpSocket?.remoteAddress}:${_tcpSocket?.remotePort}');
      
      _tcpSocket?.listen(
        (Uint8List data) {
          final message = String.fromCharCodes(data);
          print('Received: $message');
        },
        onError: (error) {
          print('Error: $error');
          _isConnected = false;
          _tcpSocket?.close();
        },
        onDone: () {
          print('Server disconnected');
          _isConnected = false;
          _tcpSocket?.close();
        },
      );
    } catch (e) {
      print('Error connecting to TCP server: $e');
    }
  }

  void sendTcpMessage(String message) {
    if (_tcpSocket != null && _isConnected) {
      _tcpSocket?.write(message);
    }
  }

  void handleClient(Socket client) {
    print('Connection from ${client.remoteAddress}:${client.remotePort}');
    
    client.listen(
      (Uint8List data) {
        final message = String.fromCharCodes(data);
        print('Received from client: $message');
        // Echo the message back
        client.write('Server received: $message');
      },
      onError: (error) {
        print('Error: $error');
        client.close();
      },
      onDone: () {
        print('Client disconnected');
        client.close();
      },
    );
  }

  // UDP Socket Implementation
  RawDatagramSocket? _udpSocket;

  Future<void> createUdpSocket(String host, int port) async {
    try {
      _udpSocket = await RawDatagramSocket.bind(host, port);
      print('UDP Socket bound to ${_udpSocket?.address}:${_udpSocket?.port}');
      
      _udpSocket?.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final datagram = _udpSocket?.receive();
            if (datagram != null) {
              final message = String.fromCharCodes(datagram.data);
              print('Received UDP message: $message from ${datagram.address}:${datagram.port}');
            }
          }
        },
        onError: (error) {
          print('UDP Socket error: $error');
        },
        onDone: () {
          print('UDP Socket closed');
        },
      );
    } catch (e) {
      print('Error creating UDP socket: $e');
    }
  }

  void sendUdpMessage(String message, InternetAddress address, int port) {
    if (_udpSocket != null) {
      final data = Uint8List.fromList(message.codeUnits);
      _udpSocket?.send(data, address, port);
    }
  }

  void dispose() {
    _tcpSocket?.close();
    _udpSocket?.close();
  }
}

// // Usage example:
// void main() async {
//   final networkService = NetworkService();
  
//   // TCP Server example
//   await networkService.createTcpServer('0.0.0.0', 8080);
  
//   // TCP Client example
//   await networkService.connectToTcpServer('127.0.0.1', 8080);
//   networkService.sendTcpMessage('Hello Server!');
  
//   // UDP example
//   await networkService.createUdpSocket('0.0.0.0', 8081);
//   networkService.sendUdpMessage(
//     'Hello UDP!',
//     InternetAddress('127.0.0.1'),
//     8081
//   );
// }