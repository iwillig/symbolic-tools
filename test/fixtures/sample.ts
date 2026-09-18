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

/**
 * Shouts a word by capitalizing it and adding an exclamation mark.
 */
function shout(word: string): string {
  return capitalize(word) + "!";
}

// standalone comment, not attached to anything
