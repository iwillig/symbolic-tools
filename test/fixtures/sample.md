# Title

Some intro text.

A paragraph that
wraps onto a second line.

## Subheading

```erlang
foo() -> ok.
```

### Sub-subheading

```
no lang here
```

## Examples

```erlang
greet(Name) ->
    hello(Name).

hello(Name) ->
    io:format("hi ~s~n", [Name]).
```

```ts
function shout(word: string): string {
  return word.toUpperCase();
}
```

```sh
deploy() {
  build
}
```

## More Structure

- unordered one
- unordered two

1. ordered one
2. ordered two

- [ ] todo item
- [x] done item

> a quoted line
> a continued quote

| Col A | Col B |
| ----- | ----- |
| x     | 1     |
| y     | 2     |

    an indented example

[a ref]: https://example.com/ref "Ref Title"
