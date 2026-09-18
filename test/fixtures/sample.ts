function foo(x: number) {
  bar(x);
  this.baz.qux(x, 1);
}

function other() {
  bar(1);
}
