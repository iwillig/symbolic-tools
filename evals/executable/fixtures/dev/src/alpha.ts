export function foo(value: number): number {
  return bar(value);
}

export function bar(value: number): number {
  return value + 1;
}

export function idle(): string {
  return "idle";
}
