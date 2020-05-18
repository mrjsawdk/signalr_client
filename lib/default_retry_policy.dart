import 'iretry_policy.dart';

class DefaultRetryPolicy implements IRetryPolicy {
  
  // 0, 2, 10, 30 second delays before reconnect attempts.
  static const DEFAULT_RETRY_DELAYS_IN_MILLISECONDS = [0, 2000, 10000, 30000, null];

  final List<int> _retryDelays;

  DefaultRetryPolicy([List<int> retryDelays]) : this._retryDelays = (retryDelays == null ? DEFAULT_RETRY_DELAYS_IN_MILLISECONDS : retryDelays);

  @override
  int nextRetryDelayInMilliseconds(RetryContext retryContext) {
    if(retryContext.previousRetryCount < _retryDelays.length)
      return _retryDelays[retryContext.previousRetryCount];
    return null;
  }
}