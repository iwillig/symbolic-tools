function foo(x: number) {
  bar(x);
  this.baz.qux(x, 1);
}

function other() {
  bar(1);
}

// Capitalizes the first letter of a word.
function capitalize(word: string): string {
  return word.toUpperCase();
}

// standalone comment, not attached to anything
