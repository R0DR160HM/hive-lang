# Proposal — Naming the derived codec

**Status: agreed, in progress.** On landing this is part of
[14](../14-stdlib.md#147-hivejson) and a row in [18](../18-conformance.md).

This removes the `with <Type>` clause **without adding any syntax**, and without
changing how a document is read.

## 1 Why

[04](../04-declarations.md#41-type) says every declared type gets, derived from
its declaration and emitted only where used, *"a deep copy, a total order, a JSON
codec, and a structural digest"*. Three of those are already reachable through
ordinary code — the order through `sort`, the digest through
[`hive.syslink`](../14-stdlib.md#1410-hivesyslink), the copy implicitly on every
binding. **The codec is the only one with no name**, and `with <Type>` is the
workaround for that.

It is a poor one for three reasons.

It is **written at the call site**, which
[11](../11-generics.md#111-where-a-variable-is-pinned-down) says the language
never does — *"none of the three is written at the call site"*.
`hive.json.parse(text) with User` is the one construct that breaks that rule.

It **shares a keyword**. [05](../05-expressions.md#58-with-clauses) has to open
by admitting it: *"Two unrelated clauses share the `with` keyword, told apart by
the word after it."*

And it is **a clause rather than a name**, so the thing it reaches — a codec the
compiler already built — stays unnameable.

## 2 `T.fromJson`

Give the codec a name, using syntax that already exists:

```hive
User.fromJson(text)          // Result<User, hive.json.JsonError>
```

`Type.member(args)` is character-for-character what `Result.Ok(v)` and
`hive.sql.DatabaseDriver.SQLite()` already are. There is **no new token, no new
grammar production, and no new `Ty`**. Name resolution grows one case, alongside
the three kinds of `X.y` it already tells apart.

Because the subject is a *type* and not a value, `fromJson` never collides with
a field: a field is reached through a value (`u.fromJson`), and a type name is
never a value. See [§2.3](#23-the-one-collision) for the single exception.

### 2.1 How a document is read is unchanged

Everything behind the name stays exactly as it is today. A union is written and
read as **one object whose single key is the variant's name**, a field-less
variant carrying an empty object:

```
Breed.Zombie              {"Zombie":{}}
Fiend(7, Breed.Merman)    {"id":7,"breed":{"Merman":{}}}
```

A JSON `null` still selects the first field-less variant, a key naming no
variant is still an error listing the ones there are, and a field a type does
not declare is still ignored. **This proposal renames the entrance and touches
nothing behind it** — the wire format does not move, `hive.json.encode` is
untouched, [`hive.syslink`](../14-stdlib.md#1410-hivesyslink) is unaffected, and
every document that decodes today decodes to the same thing after.

### 2.2 A variant names its own codec

Both levels get a name, and they read the two forms a document arrives in:

```hive
type Sig {
	Ping
	Move { x: Int, y: Int }
}

Sig.fromJson(text)           // the whole union: {"Move":{"x":1,"y":2}}
Sig.Move.fromJson(text)      // this variant's payload alone: {"x":1,"y":2}
```

`Sig.fromJson` reads the key and dispatches, as it does now. `Sig.Move.fromJson`
is for a document whose variant the caller already knows — an endpoint that only
ever returns one — and it takes the payload **without the wrapper**.

Both answer `Result<Sig, hive.json.JsonError>`. A variant is not a type of its
own in Hive ([03](../03-types.md#34-declared-types)) — narrowing is what
patterns are for — so `Sig.Move.fromJson` builds a `Sig` that *is* a `Move`, and
reading the fields is still `is Sig.Move(x, y)`.

For a field-less variant the payload is `{}`, so `Sig.Ping.fromJson("{}")` is
well defined and rarely useful. It is worth having so the rule has no hole in it.

The variant decoder is **emitted only where it is used**, beside the union
decoder rather than in place of it, so a program that never writes
`T.Variant.fromJson` carries exactly the Go it carries today.

### 2.3 The one collision

For a **field-less** variant, `Sig.Ping` is already a value. So if `Sig` also
declared a field called `fromJson`, then `Sig.Ping.fromJson` would have two
readings: the derived decoder for `Ping`, and that field of the value `Sig.Ping`.

`fromJson` is therefore **a reserved field name on a declared type**, and
declaring one is a compile error naming both readings — the same treatment
[01](../01-lexical.md#14-names-have-shapes) gives a miscased keyword:

```hive
type Sig {
	Ping
	fromJson: Str    // compile error: `fromJson` is the name of the codec every
}                    // type derives, so a field cannot also be called that
```

This is the whole cost of the member spelling, and it is one name.

## 3 What replaces each `with`

| today | becomes |
| --- | --- |
| `hive.json.parse(text) with T` | `T.fromJson(text)` |
| `hive.json.parse(text) with Table` | `hive.json.flatten(text)` |
| `hive.crypto.jwtVerify(tok, sec) with T` | `jwtVerify(tok, sec)` → `Result<Str, _>`, then `T.fromJson(claims)` |
| `hive.crypto.jwtDecode(tok) with T` | `jwtDecode(tok)` → `Result<Str, _>`, then `T.fromJson(claims)` |

`hive.json.parse` **disappears**. Its two meanings were never one call: one
decodes a declared shape, the other flattens a document into `[path, value]`
rows. The second is now `hive.json.flatten(text)`, which says what it does and
needs no type to say it. (It is distinct from `hive.json.table(text)`, which
reads a JSON *array of flat objects* as a headered `Table`.)

**`jwtVerify` and `jwtDecode` stop decoding.** They answer with the claims as
`Str`, and the caller decodes them like any other JSON. Two Results to unwrap
instead of one, at four call sites — and in exchange `hive.crypto` stops knowing
about JSON codecs, and the two failures separate properly: a bad signature or an
expired token is a `CryptoError`, a claims object of the wrong shape is a
`JsonError`. Today they arrive mashed into one.

Every call keeps working where it stands, which is the point of a name over a
declared destination:

```hive
if Greeting.fromJson(body) is Result.Ok(g) { … }
parsed := Greeting.fromJson(body)
return Up.fromJson(text)
```

`hive.json.encode(value)` is untouched, in both its signature and its output.

## 4 What the compiler enforces

* **`fromJson` as a field name** is a compile error ([§2.3](#23-the-one-collision)).
* **`T.fromJson` where `T` is not a declared type** is refused where it is
  written, the way any unresolved name is.
* **`T.Variant.fromJson` where `Variant` is not one of `T`'s** is a compile error
  naming the variants there are.
* **A type JSON cannot carry** is unchanged: the error is reported when the codec
  is derived, not when it is called.

`with <Type>` is **removed outright, with no migration diagnostic**. Hive is
before v1, the clause and its call sites change in one commit, and a
transitional error would be surface to write, test and then delete.
`with timeout` is untouched and becomes the only `with` in the language;
[05](../05-expressions.md#58-with-clauses) loses its opening caveat.

## 5 Lowering

| construct | becomes |
| --- | --- |
| `T.fromJson(text)` | `hive.JsonParse(text, <the decoder T already derives>)` |
| `T.Variant.fromJson(text)` | `hive.JsonParse(text, <a decoder for that variant's fields>)` |
| `hive.json.flatten(text)` | `hive.JsonParse(text, hive.JsonFlatten)` |

The type-level decoder is the one `decoderRef` already writes, unchanged. The
variant form emits one small function per variant actually named, decoding that
variant's own fields together with the type's shared ones.

## 6 Migration

**27 call sites**, all mechanical. Nothing changes position or nesting; the
clause becomes part of the callee.

| file | sites |
| --- | --- |
| `test/e2e/json.hive` | 10 |
| `examples/04-crypto/crypto.hive` | 4 |
| `test/emit.test.hive` | 4 |
| `examples/03-networking/http.hive` | 2 |
| `examples/19-multiplayer-fps/lib/wire.hive` | 2 |
| `examples/22-formula-kart/lib/wire.hive` | 2 |
| `examples/16-password-vault/vault.hive` | 1 |
| `test/parser.test.hive`, `test/check.test.hive` | 1 each |

Exactly one is the `Table` form (`http.hive:77`), and four are `jwtVerify` /
`jwtDecode`, which also grow a second unwrap. Four further sites are prose —
header comments in `http.hive`, both `wire.hive` files and `vault.hive`.

Because the wire format does not change, **no example needs rewriting** beyond
its call sites, and no type has to be reshaped.

The spec changes are [05](../05-expressions.md) §5.8 (the clause goes),
[02](../02-grammar.md) (the production goes),
[14](../14-stdlib.md#147-hivejson) and [04](../04-declarations.md#annotations).
No chapter gains a construct: this is a net deletion from the grammar.

## 7 What this deliberately does not add

Two earlier drafts were rejected, and the reasons are worth keeping.

**A first-class spec value** — `@T`, with a `hive.meta` module to walk it. *A
mechanism justified by four call sites is a worse bargain than the clause it
replaces.* `with <Type>` at least reuses an existing keyword; a new sigil serving
the same four calls would not, and its real justification — a metaprogramming
layer — was speculative.

**Structural dispatch**, dropping the variant name from the wire so a document
could arrive untagged. Rejected on evidence: it made `encode` lossy for
field-less variants, and the refusal to decode propagated through any type
containing an enumeration, taking two working examples with it
(`19-multiplayer-fps` through `Breed`, `13-distributed-actors` through `Note`).

`fromJson` is not a mechanism. It is a name for something the compiler already
builds, and it generalises on its own terms: a derived `toJson`, or a codec for
another format, is the same shape and needs no new decision. None of this
forecloses metaprogramming; if a reason for it arrives, it gets designed then.

## 8 Decisions taken

| question | decision |
| --- | --- |
| How is the codec named? | `T.fromJson` — a derived member, no new syntax. [§2](#2-tfromjson) |
| Does dispatch change? | No. Tagged, `{"Variant":{…}}`, exactly as today. [§2.1](#21-how-a-document-is-read-is-unchanged) |
| Does the wire format change? | No. `encode` is untouched and `hive.syslink` is unaffected. [§2.1](#21-how-a-document-is-read-is-unchanged) |
| Do variants get a codec? | Yes. `T.Variant.fromJson` reads the payload without the wrapper. [§2.2](#22-a-variant-names-its-own-codec) |
| What does the variant form return? | `Result<T, _>` — a variant is not a type of its own. [§2.2](#22-a-variant-names-its-own-codec) |
| What about `with Table`? | `hive.json.flatten(text)`. It was never "the codec `Table` derives". [§3](#3-what-replaces-each-with) |
| What about JWT? | `jwtVerify` / `jwtDecode` answer with the claims as `Str`; the caller decodes. [§3](#3-what-replaces-each-with) |
| Is there a migration diagnostic? | No. Pre-v1, it all moves in one commit. [§4](#4-what-the-compiler-enforces) |
| Is `fromJson` reserved? | Yes, as a field name on a declared type. [§2.3](#23-the-one-collision) |
