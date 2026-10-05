function foo(a) {
  bar(a);
  file.read(a);
  this.baz.qux(a, a);
  return new Error("boom");
}
