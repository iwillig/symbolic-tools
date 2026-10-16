export function greet(name: string): string {
  return format(name);
}

export function format(name: string): string {
  return name.trim();
}

export function unused(): boolean {
  return true;
}
