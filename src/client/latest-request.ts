export type LatestRequestHandle = {
  signal: AbortSignal;
  isCurrent(): boolean;
};

export class LatestRequest {
  private controller: AbortController | null = null;

  start(): LatestRequestHandle {
    this.controller?.abort();

    const controller = new AbortController();
    this.controller = controller;

    return {
      signal: controller.signal,
      isCurrent: () => this.controller === controller && !controller.signal.aborted
    };
  }

  cancel() {
    this.controller?.abort();
    this.controller = null;
  }
}
