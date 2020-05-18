import 'package:logging/logging.dart';
import 'default_retry_policy.dart';
import 'iretry_policy.dart';

import 'errors.dart';
import 'http_connection.dart';
import 'http_connection_options.dart';
import 'hub_connection.dart';
import 'ihub_protocol.dart';
import 'itransport.dart';
import 'json_hub_protocol.dart';
import 'utils.dart';

/// A builder for configuring {@link @aspnet/signalr.HubConnection} instances.
class HubConnectionBuilder {
  // Properties

  IHubProtocol _protocol;

  HttpConnectionOptions _httpConnectionOptions;

  String _url;

  Logger _logger;

  IRetryPolicy _reconnectPolicy;

  /// Configures console logging for the HubConnection.
  ///
  /// logger: this logger with the already configured log level will be used.
  /// Returns the builder instance, for chaining.
  ///
  HubConnectionBuilder configureLogging(Logger logger) {
    _logger = logger;
    return this;
  }

  /// Configures the {@link @aspnet/signalr.HubConnection} to use HTTP-based transports to connect to the specified URL.
  ///
  /// url: The URL the connection will use.
  /// options: An options object used to configure the connection.
  /// transportType: The requested (and supported) transportedType.
  /// Use either options or transportType.
  /// Returns the builder instance, for chaining.
  ///
  HubConnectionBuilder withUrl(String url,
      {HttpConnectionOptions options, HttpTransportType transportTyp}) {
    assert(!isStringEmpty(url));
    assert(!(options != null && transportTyp != null));

    _url = url;

    if (options != null) {
      _httpConnectionOptions = options;
    } else {
      _httpConnectionOptions = HttpConnectionOptions(transport: transportTyp);
    }

    return this;
  }

  /// Configures the HubConnection to use the specified Hub Protocol.
  ///
  /// protocol: The IHubProtocol implementation to use.
  ///
  HubConnectionBuilder withHubProtocol(IHubProtocol protocol) {
    assert(protocol != null);

    _protocol = protocol;
    return this;
  }

  /// Configures the {@link @microsoft/signalr.HubConnection} to automatically attempt to reconnect if the connection is lost.
  /// By default, the client will wait 0, 2, 10 and 30 seconds respectively before trying up to 4 reconnect attempts.
  ///
  HubConnectionBuilder withAutomaticReconnect() {
    _reconnectPolicy = new DefaultRetryPolicy();
    return this;
  }

  /// Configures the {@link @microsoft/signalr.HubConnection} to automatically attempt to reconnect if the connection is lost.
  ///  
  /// @param {number[]} retryDelays An array containing the delays in milliseconds before trying each reconnect attempt.
  /// The length of the array represents how many failed reconnect attempts it takes before the client will stop attempting to reconnect.
  /// 
  HubConnectionBuilder withAutomaticReconnectAndCustomDelays(List<int> retryDelays) {
    _reconnectPolicy = new DefaultRetryPolicy(retryDelays);
    return this;
  }

  /// Configures the {@link @microsoft/signalr.HubConnection} to automatically attempt to reconnect if the connection is lost.
  ///
  ///@param {IRetryPolicy} reconnectPolicy An {@link @microsoft/signalR.IRetryPolicy} that controls the timing and number of reconnect attempts.
  ///
  HubConnectionBuilder withAutomaticReconnectAndCustomPolicy(IRetryPolicy reconnectPolicy) {
    _reconnectPolicy = reconnectPolicy;
    return this;
  }

  /// Creates a HubConnection from the configuration options specified in this builder.
  ///
  /// Returns the configured HubConnection.
  ///
  HubConnection build() {
    // If httpConnectionOptions has a logger, use it. Otherwise, override it with the one
    // provided to configureLogger
    final httpConnectionOptions =
        _httpConnectionOptions ?? HttpConnectionOptions();

    // Now create the connection
    if (isStringEmpty(_url)) {
      throw new GeneralError(
          "The 'HubConnectionBuilder.withUrl' method must be called before building the connection.");
    }
    final connection = HttpConnection(_url, options: httpConnectionOptions);
    return HubConnection(connection, _logger, _protocol ?? JsonHubProtocol(), _reconnectPolicy);
  }
}
