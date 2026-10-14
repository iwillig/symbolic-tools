declare const inngest: {
  createFunction(...args: unknown[]): unknown;
};

function findSmsDecision(event: unknown) {
  return event;
}

function findAmbiguousDecision() {
  return undefined;
}

export const handleSmsVoteCommand = inngest.createFunction(
  {},
  {},
  async ({ event }: { event: unknown }) => {
    step.run('find-decision', async () => {
      findSmsDecision(event);
    });
  },
);

export const ambiguousHandler = inngest.createFunction(
  async () => {
    findAmbiguousDecision();
  },
  async () => undefined,
);
