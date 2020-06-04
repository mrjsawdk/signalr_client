import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'errors.dart';
import 'itransport.dart';
import 'utils.dart';

class WebSocketTransport implements ITransport {
  // Properties

  Logger _logger;
  AccessTokenFactory _accessTokenFactory;
  bool _logMessageContent;
  WebSocket _webSocket;
  StreamSubscription<Object> _webSocketListenSub;

  @override
  OnClose onClose;

  @override
  OnReceive onReceive;

  // Methods
  WebSocketTransport(AccessTokenFactory accessTokenFactory, Logger logger,
      bool logMessageContent)
      : this._accessTokenFactory = accessTokenFactory,
        this._logger = logger,
        this._logMessageContent = logMessageContent;

  @override
  Future<void> connect(String url, TransferFormat transferFormat) async {
    assert(url != null);
    assert(transferFormat != null);

    _logger?.finest("(WebSockets transport) Connecting");

    if (_accessTokenFactory != null) {
      final token = await _accessTokenFactory();
      if (!isStringEmpty(token)) {
        final encodedToken = Uri.encodeComponent(token);
        url +=
            (url.indexOf("?") < 0 ? "?" : "&") + "access_token=$encodedToken";
      }
    }

    url = url.replaceFirst('http', 'ws');
    _logger?.finest("WebSocket try connecting to '$url'.");
    _webSocket = await WebSocket.connect(url);
    _logger?.info("WebSocket connected to '$url'.");
    _webSocketListenSub = _webSocket.listen(
      // onData
      (Object message) {
        //_logger.log(LogLevel.Trace, "(WebSockets transport) data received. ${getDataDetail(message.data, this.logMessageContent)}.");
        _logger?.finest("(WebSockets transport) data received.");
        if (onReceive != null) {
          onReceive(message);
        }
      },

      // onError
      onError: (Object error) {
        if (error != null) {
          return Future.error(error);
        }
        return Future.value(null);
      },

      // onDone
      onDone: () {
        if(_webSocket.readyState == WebSocket.open) {
          return _close(null);
        } else {
          return Future.error(GeneralError("There was an error with the transport."));
        }
      },
    );
  }

  @override
  Future<void> send(Object data) {
    if ((_webSocket != null) && (_webSocket.readyState == WebSocket.open)) {
      //_logger.log(LogLevel.Trace, "(WebSockets transport) sending data. ${getDataDetail(data, this.logMessageContent)}.");
      _logger?.finest("(WebSockets transport) sending data.");

      if (data is String) {
        _webSocket.add(data);
      } else if (data is Uint8List) {
        _webSocket.add(data);
      } else {
        throw GeneralError("Content type is not handeled.");
      }

      return Future.value(null);
    }

    return Future.error(GeneralError("WebSocket is not in the OPEN state"));
  }

  @override
  Future<void> stop(Error error) async {
    if (_webSocket != null) {
      _close(error);
    }

    return Future.value(null);
  }

  Future<void> _close(Error error) async{
    _logger?.finest("(WebSockets transport) socket closed.");
    // Clear websocket handlers because we are considering the socket closed now
    if (_webSocketListenSub != null) {
      await _webSocketListenSub.cancel();
      _webSocketListenSub = null;
    }
    _webSocket.close();
    _webSocket = null;

    // Manually invoke onclose callback inline so we know the HttpConnection was closed properly before returning
    // This also solves an issue where websocket.onclose could take 18+ seconds to trigger during network disconnects
      
    if(onClose != null) {
      onClose(error != null ? error : GeneralError(error?.toString()));
    }
  }
}
