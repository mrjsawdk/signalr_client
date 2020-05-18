class RetryContext {
    ///
    /// The number of consecutive failed tries so far.
    ///
    final previousRetryCount;

    ///
    /// The amount of time in milliseconds spent retrying so far.
    ///
    final int elapsedMilliseconds;

    ///
    ///The error that forced the upcoming retry.
    ///
    final Exception retryReason;
    
    RetryContext(int previousRetryCount,int elapsedMilliseconds, Exception retryReason) :
    this.previousRetryCount = previousRetryCount,
    this.elapsedMilliseconds = elapsedMilliseconds,
    this.retryReason = retryReason;
}

abstract class IRetryPolicy {
  /// Called after the transport loses the connection.
  ///
  /// @param {RetryContext} retryContext Details related to the retry event to help determine how long to wait for the next retry.
  ///
  /// @returns {int | null} The amount of time in milliseconds to wait before the next retry. `null` tells the client to stop retrying.
  ////
    int nextRetryDelayInMilliseconds(RetryContext retryContext);
}