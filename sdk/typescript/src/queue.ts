/**
 * A push source that many consumers can read as an async iterable.
 *
 * Everything a run produces goes through one of these. Late subscribers get
 * the whole history first, which is what lets `await run` and
 * `for await (run)` be the same run: the promise path is just another
 * consumer, and it does not race the streaming one for events.
 */
export class Broadcast<T> {
  private readonly buffer: T[] = [];
  private readonly waiters = new Set<() => void>();
  private closed = false;
  private failure: unknown = null;

  push(value: T): void {
    if (this.closed) return;
    this.buffer.push(value);
    this.wake();
  }

  close(error?: unknown): void {
    if (this.closed) return;
    this.closed = true;
    if (error !== undefined) this.failure = error;
    this.wake();
  }

  private wake(): void {
    for (const waiter of [...this.waiters]) waiter();
    this.waiters.clear();
  }

  private wait(): Promise<void> {
    return new Promise((resolve) => this.waiters.add(resolve));
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<T> {
    let index = 0;
    while (true) {
      while (index < this.buffer.length) {
        yield this.buffer[index++] as T;
      }
      if (this.closed) {
        if (this.failure !== null) throw this.failure;
        return;
      }
      await this.wait();
    }
  }
}

/** A promise whose settlement is triggered from elsewhere. */
export function deferred<T>(): {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (error: unknown) => void;
} {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  // Nobody may have attached a handler yet; the Run surfaces this failure on
  // whichever path the caller actually awaits.
  promise.catch(() => {});
  return { promise, resolve, reject };
}
