import { describe, expect, it } from "vitest";

import { LatestRequest } from "../src/client/latest-request";

describe("LatestRequest", () => {
  it("aborts the previous request and marks only the newest as current", () => {
    const requests = new LatestRequest();
    const previous = requests.start();
    const latest = requests.start();

    expect(previous.signal.aborted).toBe(true);
    expect(previous.isCurrent()).toBe(false);
    expect(latest.signal.aborted).toBe(false);
    expect(latest.isCurrent()).toBe(true);
  });

  it("invalidates the active request when cancelled", () => {
    const requests = new LatestRequest();
    const active = requests.start();

    requests.cancel();

    expect(active.signal.aborted).toBe(true);
    expect(active.isCurrent()).toBe(false);
  });
});
