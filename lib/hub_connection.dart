import 'dart:async';

import 'package:logging/logging.dart';
import 'iretry_policy.dart';

import 'errors.dart';
import 'handshake_protocol.dart';
import 'iconnection.dart';
import 'ihub_protocol.dart';
import 'utils.dart';

const int DEFAULT_TIMEOUT_IN_MS = 30 * 1000;
const int DEFAULT_PING_INTERVAL_IN_MS = 15 * 1000;

/// Describes the current state of the {@link HubConnection} to the server.
enum HubConnectionState {
  /// The hub connection is disconnecting.
  Disconnecting,

  /// The hub connection is disconnected.
  Disconnected,

  /// The hub connection is connected.
  Connected,

  /// The hub connection is connecting.
  Connecting,

  /// The hub connection is reconnecting.
  Reconnecting,
}

typedef InvocationEventCallback = void Function(
    HubMessageBase invocationEvent, Exception error);
typedef MethodInvacationFunc = void Function(List<Object> arguments);
typedef ClosedCallback = void Function(Exception error);
typedef ReconnectingCallback = void Function(Exception error);
typedef ReconnectedCallback = void Function(String connectionId);

/// Represents a connection to a SignalR Hub
class HubConnection {
  // Either a string (json) or Uint8List (binary);
  Object _cachedPingMessage;
  final IConnection _connection;
  final Logger _logger;
  final IHubProtocol _protocol;
  final HandshakeProtocol _handshakeProtocol;

  Map<String, InvocationEventCallback> _callbacks;
  Map<String, List<MethodInvacationFunc>> _methods;
  List<ClosedCallback> _closedCallbacks;
  List<ReconnectingCallback> _reconnectingCallbacks;
  List<ReconnectedCallback> _reconnectedCallbacks;

  int _id;
  bool _receivedHandshakeResponse;
  Completer _handshakeCompleter;

  HubConnectionState _connectionState;

  bool _isInReconnectWait;
  Timer _timeoutTimer;
  Timer _pingServerTimer;

  /// The server timeout in milliseconds.
  ///
  /// If this timeout elapses without receiving any messages from the server, the connection will be terminated with an error.
  /// The default timeout value is 30,000 milliseconds (30 seconds).
  ///
  int serverTimeoutInMilliseconds;

  /// Default interval at which to ping the server.
  ///
  /// The default value is 15,000 milliseconds (15 seconds).
  /// Allows the server to detect hard disconnects (like when a client unplugs their computer).
  ///
  int keepAliveIntervalInMilliseconds;

  Exception _stopDuringStartError;

  Future<void> _startFuture;

  Future<void> _stopFuture;

  final IRetryPolicy _reconnectPolicy;

  /// Indicates the state of the {@link HubConnection} to the server.
  HubConnectionState get state => this._connectionState;

  HubConnection(IConnection connection, Logger logger, IHubProtocol protocol, [IRetryPolicy reconnectPolicy])
      : assert(connection != null),
        assert(protocol != null),
        _reconnectPolicy = reconnectPolicy,
        _connection = connection,
        _logger = logger,
        _protocol = protocol,
        _handshakeProtocol = HandshakeProtocol() {
    serverTimeoutInMilliseconds = DEFAULT_TIMEOUT_IN_MS;
    keepAliveIntervalInMilliseconds = DEFAULT_PING_INTERVAL_IN_MS;
    _isInReconnectWait = false;

    _connection.onreceive = _processIncomingData;
    _connection.onclose = _connectionClosed;

    _callbacks = {};
    _methods = {};
    _closedCallbacks = [];
    _reconnectingCallbacks = [];
    _reconnectedCallbacks = [];
    _id = 0;
    _receivedHandshakeResponse = false;
    _connectionState = HubConnectionState.Disconnected;

    _cachedPingMessage = _protocol.writeMessage(PingMessage());
  }

  /// Starts the connection.
  ///
  /// Returns a Promise that resolves when the connection has been successfully established, or rejects with an error.
  ///
  Future<void> start() {
    _startFuture = _startWithStateTransitions();
    return _startFuture;
  }

  Future<void> _startWithStateTransitions() async {
    if (_connectionState != HubConnectionState.Disconnected) {
      throw new Exception("Cannot start a HubConnection that is not in the 'Disconnected' state.");
    }

    _connectionState = HubConnectionState.Connecting;
    _logger?.fine("Starting HubConnection.");

    try {
      await _startInternal();

      _connectionState = HubConnectionState.Connected;
      _logger?.fine("HubConnection connected successfully.");
    } catch (e) {
      _connectionState = HubConnectionState.Disconnected;
      _logger?.fine("HubConnection failed to start successfully because of error '$e'.");
      rethrow;
    }
  }

  Future<void> _startInternal() async {
    _logger?.finer("Starting HubConnection.");

    _stopDuringStartError = null;
    _receivedHandshakeResponse = false;
    // Set up the Future before any connection is started otherwise it could race with received messages
    var completer =  Completer(); //keep the reference in scope even if local field is nulled
    _handshakeCompleter = completer;
    await _connection.start(transferFormat: _protocol.transferFormat);

    try {
      final handshakeRequest = HandshakeRequestMessage(this._protocol.name, this._protocol.version);

      _logger?.finer("Sending handshake request.");
    
      await _sendMessage(_handshakeProtocol.writeHandshakeRequest(handshakeRequest));

      _logger?.info("Using HubProtocol '${_protocol.name}'.");

      // defensively cleanup timeout in case we receive a message from the server before we finish start
      _cleanupTimeoutTimer();
      _resetTimeoutPeriod();
      _resetKeepAliveInterval();

      // Wait for the handshake to complete before marking connection as connected
      await completer.future;

      // It's important to check the stopDuringStartError instead of just relying on the handshakePromise
      // being rejected on close, because this continuation can run after both the handshake completed successfully
      // and the connection was closed.
      if (_stopDuringStartError != null) {
        // It's important to throw instead of returning a rejected promise, because we don't want to allow any state
        // transitions to occur between now and the calling code observing the exceptions. Returning a rejected promise
        // will cause the calling continuation to get scheduled to run later.
        throw _stopDuringStartError;
      }

    } catch(e) {
      _logger?.fine("Hub handshake failed with error '$e' during start(). Stopping HubConnection.");

      _cleanupTimeoutTimer();
      _cleanupServerPingTimer();

      // HttpConnection.stop() should not complete until after the onclose callback is invoked.
      // This will transition the HubConnection to the disconnected state before HttpConnection.stop() completes.
      await _connection.stop(e);
      rethrow;
    }
  }


  /// Stops the connection.
  ///
  /// Returns a Promise that resolves when the connection has been successfully terminated, or rejects with an error.
  ///
  Future<void> stop() async {
    // Capture the start promise before the connection might be restarted in an onclose callback.
    var startFuture = _startFuture;

    _stopFuture = _stopInternal();
    await _stopFuture;

    try {
      // Awaiting undefined continues immediately
      await startFuture;
    } catch (e) {
      // This exception is returned to the user as a rejected Promise from the start method.
    }
  }

  Future<void> _stopInternal([Exception error]) async {
    var completer = new Completer();

    if (_connectionState == HubConnectionState.Disconnected) {
      _logger?.fine("Call to HubConnection.stop($error) ignored because it is already in the disconnected state.");
      return completer.future;
    }

    if (_connectionState == HubConnectionState.Disconnecting) {
      _logger?.fine("Call to HttpConnection.stop($error) ignored because the connection is already in the disconnecting state.");
      return _stopFuture;
    }

    _connectionState = HubConnectionState.Disconnecting;

    _logger?.fine("Stopping HubConnection.");

    if (_isInReconnectWait) {
      // We're in a reconnect delay which means the underlying connection is currently already stopped.
      // Just clear the handle to stop the reconnect loop (which no one is waiting on thankfully) and
      // fire the onclose callbacks.
      _logger?.fine("Connection stopped during reconnect delay. Done reconnecting.");

      _isInReconnectWait = false;

      _completeClose();
      return completer.future;
    }

    _cleanupTimeoutTimer();
    _cleanupServerPingTimer();
    _stopDuringStartError = error == null ? new Exception("The connection was stopped before the hub handshake could complete.") : error;

    // HttpConnection.stop() should not complete until after either HttpConnection.start() fails
    // or the onclose callback is invoked. The onclose callback will transition the HubConnection
    // to the disconnected state if need be before HttpConnection.stop() completes.
    return _connection.stop(error);
  }

  /// Invokes a streaming hub method on the server using the specified name and arguments.
  ///
  /// T: The type of the items returned by the server.
  /// methodName: The name of the server method to invoke.
  /// args: The arguments used to invoke the server method.
  /// Returns an object that yields results from the server as they are received.
  ///
  Stream<Object> stream(String methodName, List<Object> args) {
    final invocationMessage = _createStreamInvocation(methodName, args);

    var pauseSendingItems = false;
    final StreamController streamController = StreamController<Object>(
      onCancel: () {
        final cancelMessage =
            _createCancelInvocation(invocationMessage.invocationId);
        final formatedCancelMessage = _protocol.writeMessage(cancelMessage);
        _callbacks.remove(invocationMessage.invocationId);
        _sendMessage(formatedCancelMessage);
      },
      onPause: () => pauseSendingItems = true,
      onResume: () => pauseSendingItems = false,
    );

    _callbacks[invocationMessage.invocationId] =
        (HubMessageBase invocationEvent, Exception error) {
      if (error != null) {
        streamController.addError(error);
        return;
      } else if (invocationEvent != null) {
        if (invocationEvent is CompletionMessage) {
          if (invocationEvent.error != null) {
            streamController.addError(new GeneralError(invocationEvent.error));
          } else {
            streamController.close();
          }
        } else if (invocationEvent is StreamItemMessage) {
          if (!pauseSendingItems) {
            streamController.add(invocationEvent.item);
          }
        }
      }
    };

    final formatedMessage = _protocol.writeMessage(invocationMessage);
    _sendMessage(formatedMessage).catchError((dynamic error) {
      streamController.addError(error as Error);
      _callbacks.remove(invocationMessage.invocationId);
    });

    return streamController.stream;
  }

  Future<void> _sendMessage(Object message) {
    _resetKeepAliveInterval();
    _logger?.finest("Sending message.");
    return _connection.send(message);
  }

  /// Invokes a hub method on the server using the specified name and arguments. Does not wait for a response from the receiver.
  ///
  /// The Promise returned by this method resolves when the client has sent the invocation to the server. The server may still
  /// be processing the invocation.
  ///
  /// methodName: The name of the server method to invoke.
  /// args: The arguments used to invoke the server method.
  /// Returns a Promise that resolves when the invocation has been successfully sent, or rejects with an error.
  ///
  Future<void> send(String methodName, List<Object> args) {
    final invocationDescriptor = _createInvocation(methodName, args, true);
    final message = _protocol.writeMessage(invocationDescriptor);
    return _sendMessage(message);
  }

  /// Invokes a hub method on the server using the specified name and arguments.
  ///
  /// The Future returned by this method resolves when the server indicates it has finished invoking the method. When the Future
  /// resolves, the server has finished invoking the method. If the server method returns a result, it is produced as the result of
  /// resolving the Promise.
  ///
  /// methodName: The name of the server method to invoke.
  /// args: The arguments used to invoke the server method.
  /// Returns a Future that resolves with the result of the server method (if any), or rejects with an error.
  ///

  Future<Object> invoke(String methodName, {List<Object> args}) {
    args = args ?? List<Object>();
    final invocationMessage = _createInvocation(methodName, args, false);

    final completer = Completer<Object>();

    _callbacks[invocationMessage.invocationId] =
        (HubMessageBase invocationEvent, Exception error) {
      if (error != null) {
        completer.completeError(error);
        return;
      } else if (invocationEvent != null) {
        if (invocationEvent is CompletionMessage) {
          if (invocationEvent.error != null) {
            completer.completeError(new GeneralError(invocationEvent.error));
          } else {
            completer.complete(invocationEvent.result);
          }
        } else {
          completer.completeError(new GeneralError(
              "Unexpected message type: ${invocationEvent.type}"));
        }
      }
    };

    final formatedMessage = _protocol.writeMessage(invocationMessage);
    _sendMessage(formatedMessage).catchError((dynamic error) {
      completer.completeError(error as Error);
      _callbacks.remove(invocationMessage.invocationId);
    });

    return completer.future;
  }

  ///  Registers a handler that will be invoked when the hub method with the specified method name is invoked.
  ///
  /// methodName: The name of the hub method to define.
  /// newMethod: The handler that will be raised when the hub method is invoked.
  ///
  void on(String methodName, MethodInvacationFunc newMethod) {
    if (isStringEmpty(methodName) || newMethod == null) {
      return;
    }

    methodName = methodName.toLowerCase();
    if (_methods[methodName] == null) {
      _methods[methodName] = [];
    }

    // Preventing adding the same handler multiple times.
    if (_methods[methodName].indexOf(newMethod) != -1) {
      return;
    }

    _methods[methodName].add(newMethod);
  }

  /// Removes the specified handler for the specified hub method.
  ///
  /// You must pass the exact same Function instance as was previously passed to HubConnection.on. Passing a different instance (even if the function
  /// body is the same) will not remove the handler.
  ///
  /// methodName: The name of the method to remove handlers for.
  /// method: The handler to remove. This must be the same Function instance as the one passed to {@link @aspnet/signalr.HubConnection.on}.
  /// If the method handler is omitted, all handlers for that method will be removed.
  ///
  void off(String methodName, {MethodInvacationFunc method}) {
    if (isStringEmpty(methodName)) {
      return;
    }

    methodName = methodName.toLowerCase();
    final handlers = _methods[methodName];
    if (handlers == null) {
      return;
    }

    if (method != null) {
      final removeIdx = handlers.indexOf(method);
      if (removeIdx != -1) {
        handlers.removeAt(removeIdx);
        if (handlers.length == 0) {
          _methods.remove(methodName);
        }
      }
    } else {
      _methods.remove(methodName);
    }
  }

  /// Registers a handler that will be invoked when the connection is closed.
  ///
  /// callback: The handler that will be invoked when the connection is closed. Optionally receives a single argument containing the error that caused the connection to close (if any).
  ///
  void onclose(ClosedCallback callback) {
    if (callback != null) {
      _closedCallbacks.add(callback);
    }
  }

  /// Registers a handler that will be invoked when the connection starts reconnecting.
  ///
  /// @param {Function} callback The handler that will be invoked when the connection starts reconnecting. Optionally receives a single argument containing the error that caused the connection to start reconnecting (if any).
  ///
  onreconnecting(ReconnectingCallback callback) {
    if (callback != null) {
      _reconnectingCallbacks.add(callback);
    }
  }

  /// Registers a handler that will be invoked when the connection successfully reconnects.
  ///
  /// @param {Function} callback The handler that will be invoked when the connection successfully reconnects.
  ///
  onreconnected(ReconnectedCallback callback) {
    if (callback != null) {
      _reconnectedCallbacks.add(callback);
    }
  }

  void _processIncomingData(Object data) {
    _cleanupTimeoutTimer();

    _logger?.finest("Incomming message");

    if (!_receivedHandshakeResponse) {
      data = _processHandshakeResponse(data);
      _receivedHandshakeResponse = true;
    }

    // Data may have all been read when processing handshake response
    if (data != null) {
      // Parse the messages
      final messages = _protocol.parseMessages(data, _logger);

      for (final message in messages) {
        _logger?.finest("Handle message of type '${message.type}'.");
        switch (message.type) {
          case MessageType.Invocation:
            _invokeClientMethod(message);
            break;
          case MessageType.StreamItem:
          case MessageType.Completion:
            final invocationMsg = message as HubInvocationMessage;
            final callback = _callbacks[invocationMsg.invocationId];
            if (callback != null) {
              if (message.type == MessageType.Completion) {
                _callbacks.remove(invocationMsg.invocationId);
              }
              callback(message, null);
            }
            break;
          case MessageType.Ping:
            // Don't care about pings
            break;
          case MessageType.Close:
            _logger?.info("Close message received from server.");
            final closeMsg = message as CloseMessage;

            var error = closeMsg.error != null ? new Exception("Server returned an error on close: " + closeMsg.error) : new Exception("Unknown error");

            if (closeMsg.allowReconnect == true) {
              // It feels wrong not to await connection.stop() here, but processIncomingData is called as part of an onreceive callback which is not async,
              // this is already the behavior for serverTimeout(), and HttpConnection.Stop() should catch and log all possible exceptions.

              // tslint:disable-next-line:no-floating-promises
            _logger?.info("Server allows reconnect. Stopping connection to initiate!");
              _connection.stop(error);
            } else {
              // We cannot await stopInternal() here, but subsequent calls to stop() will await this if stopInternal() is still ongoing.
              _stopFuture = _stopInternal(error);
            }

            break;
          default:
            _logger?.warning("Invalid message type: '${message.type}'");
            break;
        }
      }
    }

    _resetTimeoutPeriod();
  }

  /// data is either a string (json) or a Uint8List (binary)
  Object _processHandshakeResponse(Object data) {
    ParseHandshakeResponseResult handshakeResult;

    try {
      handshakeResult = _handshakeProtocol.parseHandshakeResponse(data);
    } catch (e) {
      final message = "Error parsing handshake response: '${e.toString()}'.";
      _logger?.severe(message);

      final error = GeneralError(message);

      // We don't want to wait on the stop itself.
      _connection.stop(error);
      _handshakeCompleter?.completeError(error);
      _handshakeCompleter = null;
      throw error;
    }
    if (!isStringEmpty(handshakeResult.handshakeResponseMessage.error)) {
      final message =
          "Server returned handshake error: '${handshakeResult.handshakeResponseMessage.error}'";
      _logger?.severe(message);

      _handshakeCompleter?.completeError(new GeneralError(message));
      _handshakeCompleter = null;
      // We don't want to wait on the stop itself.
      _connection.stop(GeneralError(message));
      throw GeneralError(message);
    } else {
      _logger?.finer("Server handshake complete.");
    }

    _handshakeCompleter?.complete();
    _handshakeCompleter = null;
    return handshakeResult.remainingData;
  }

  void _resetKeepAliveInterval() {
    _cleanupServerPingTimer();
    this._pingServerTimer =
        Timer.periodic(Duration(milliseconds: keepAliveIntervalInMilliseconds),
            (Timer t) async {
      if (_connectionState == HubConnectionState.Connected) {
        try {
          await _sendMessage(_cachedPingMessage);
        } catch (e) {
          // We don't care about the error. It should be seen elsewhere in the client.
          // The connection is probably in a bad or closed state now, cleanup the timer so it stops triggering
          _cleanupServerPingTimer();
        }
      }
    });
  }

  void _resetTimeoutPeriod() {
    _cleanupTimeoutTimer();
    if ((_connection.features == null) ||
        (_connection.features.inherentKeepAlive == null) ||
        (!_connection.features.inherentKeepAlive)) {
      // Set the timeout timer
      this._timeoutTimer = new Timer(Duration(milliseconds: serverTimeoutInMilliseconds), _serverTimeout);
    }
  }

  void _cleanupServerPingTimer() {
    this._pingServerTimer?.cancel();
    this._pingServerTimer = null;
  }

  void _cleanupTimeoutTimer() {
    this._timeoutTimer?.cancel();
    this._timeoutTimer = null;
  }

  void _serverTimeout() {
    // The server hasn't talked to us in a while. It doesn't like us anymore ... :(
    // Terminate the connection, but we don't need to wait on the promise.
    _logger.fine("SERVER TIMEOUT. TERMINATING!");
    _connection.stop(GeneralError(
        "Server timeout elapsed without receiving a message from the server."));
  }

  void _invokeClientMethod(InvocationMessage invocationMessage) {
    final methods = _methods[invocationMessage.target.toLowerCase()];
    if (methods != null) {
      try {
        methods.forEach((m) => m(invocationMessage.arguments));
      } catch (e) {
        _logger.severe("A callback for the method ${invocationMessage.target.toLowerCase()} threw error '$e'.");
      }

      if (!isStringEmpty(invocationMessage.invocationId)) {
        // This is not supported in v1. So we return an error to avoid blocking the server waiting for the response.
        final message =
            "Server requested a response, which is not supported in this version of the client.";
        _logger?.severe(message);

        // We don't want to wait on the stop itself.
        _stopFuture = _stopInternal(GeneralError(message));
      }
    } else {
      _logger?.warning(
          "No client method with the name '${invocationMessage.target}' found.");
    }
  }

  void _connectionClosed(Exception error) {
    final callbacks = _callbacks;
    callbacks.clear();

    if(_stopDuringStartError == null) {
      _stopDuringStartError = error != null ? error : new Exception("The underlying connection was closed before the hub handshake could complete.");
    }

    // if handshake is in progress start will be waiting for the handshake promise, so we complete it
    // if it has already completed this should just noop
    _handshakeCompleter?.completeError(error);

    final callbackError = error ??
        new GeneralError("Invocation canceled due to connection being closed.");
    callbacks.values.forEach((callback) => callback(null, callbackError));

    _cleanupTimeoutTimer();
    _cleanupServerPingTimer();

    if (_connectionState == HubConnectionState.Disconnecting) {
      _completeClose(error);
    } else if (_connectionState == HubConnectionState.Connected && _reconnectPolicy != null) {
      _reconnect(error);
    } else if (_connectionState == HubConnectionState.Connected) {
      _completeClose(error);
    }

    // If none of the above if conditions were true were called the HubConnection must be in either:
    // 1. The Connecting state in which case the handshakeResolver will complete it and stopDuringStartError will fail it.
    // 2. The Reconnecting state in which case the handshakeResolver will complete it and stopDuringStartError will fail the current reconnect attempt
    //    and potentially continue the reconnect() loop.
     // 3. The Disconnected state in which case we're already done.
  }

  int _getNextRetryDelay(int previousReconnectAttempts, int elapsedMiliSeconds, [Exception error]) {
    return _reconnectPolicy.nextRetryDelayInMilliseconds(new RetryContext(previousReconnectAttempts,elapsedMiliSeconds,error));
  }

  Future<void> _reconnect([Exception error]) async {
    
    final reconnectStartTime = DateTime.now();
    var previousReconnectAttempts = 0;
    var retryError = error != null ? error : Exception("Attempting to reconnect due to a unknown error.");

    var nextRetryDelay = _getNextRetryDelay(previousReconnectAttempts++, 0, retryError);

    if (nextRetryDelay == null) {
      _logger?.fine("Connection not reconnecting because the IRetryPolicy returned null on the first reconnect attempt.");
      _completeClose(error);
      return;
    } 
    _connectionState = HubConnectionState.Reconnecting;

    if (error != null) {
      _logger?.info("Connection reconnecting because of error '$error'.");
    } else {
      _logger?.info("Connection reconnecting.");
    }

    if (_reconnectingCallbacks.length > 0) {
      try {
        _reconnectingCallbacks.forEach((c) => c.call(error));
      } catch (e) {
        _logger?.severe("An onreconnecting callback called with error '$error' threw error '$e'.");
      }

      // Exit early if an onreconnecting callback called connection.stop().
      if (_connectionState != HubConnectionState.Reconnecting) {
        _logger?.fine("Connection left the reconnecting state in onreconnecting callback. Done reconnecting.");
        return;
      }
    }

    while (nextRetryDelay != null) {
      _logger?.info("Reconnect attempt number $previousReconnectAttempts will start in $nextRetryDelay ms.");

      _isInReconnectWait = true;
      await Future.delayed(Duration(milliseconds: nextRetryDelay));
      _isInReconnectWait = false;

      if (_connectionState != HubConnectionState.Reconnecting) {
        _logger?.fine("Connection left the reconnecting state during reconnect delay. Done reconnecting.");
        return;
      } 
      try {
        _logger?.info("Performing reconnect attempt number $previousReconnectAttempts after waiting $nextRetryDelay ms.");
        await _startInternal();

        _connectionState = HubConnectionState.Connected;
        _logger?.info("HubConnection reconnected successfully.");

        if (_reconnectedCallbacks.length > 0) {
          try {
            _reconnectedCallbacks.forEach((c) => c.call(_connection.connectionId));
          } catch (e) {
            _logger?.severe("An onreconnected callback called with connectionId '$this.connection.connectionId; threw error '$e'.");
          }
        }

        return;
        } catch (e) {
          _logger?.info("Reconnect attempt failed because of error '$e'.");

          if (_connectionState != HubConnectionState.Reconnecting) {
            _logger?.info("Connection left the reconnecting state during reconnect attempt. Done reconnecting.");
            return;
          } 
          retryError = (e is Exception) ? e : new Exception(e.toString());
          nextRetryDelay = _getNextRetryDelay(previousReconnectAttempts++, _elapsed(reconnectStartTime).inSeconds, retryError);  
        }
    }
    _logger?.info("Reconnect retries have been exhausted after ${_elapsed(reconnectStartTime).inMilliseconds} ms and $previousReconnectAttempts failed attempts. Connection disconnecting.");
    _completeClose(error);
  }

  Duration _elapsed(DateTime since) {
    return new Duration(milliseconds: (DateTime.now().millisecondsSinceEpoch - since.millisecondsSinceEpoch));
  }

  void _completeClose([Exception error]) {
    _connectionState = HubConnectionState.Disconnected;
    _closedCallbacks.forEach((callback) => callback(error));
    if(error != null) {
      _logger?.info("Connection closed with error $error.");
    }
  }

  InvocationMessage _createInvocation(
      String methodName, List<Object> args, bool nonblocking) {
    if (nonblocking) {
      return InvocationMessage(methodName, args, MessageHeaders(), null);
    } else {
      final id = _id++;
      return InvocationMessage(
          methodName, args, MessageHeaders(), id.toString());
    }
  }

  StreamInvocationMessage _createStreamInvocation(
      String methodName, List<Object> args) {
    final id = _id++;
    return StreamInvocationMessage(
        methodName, args, MessageHeaders(), id.toString());
  }

  static CancelInvocationMessage _createCancelInvocation(String id) {
    return CancelInvocationMessage(new MessageHeaders(), id);
  }
}
