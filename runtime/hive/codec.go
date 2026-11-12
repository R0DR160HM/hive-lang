// The Go for `hive.codec`: what `encode` and `T.decode` traffic in, and nothing
// about any one format. A `Codec` decides nothing at run time — which format it
// is was settled by its type.
package hive

// CodecCodec is a format, and E is what decoding in it fails with. E settles
// which format at compile time, so a value carries only what one needs at run
// time: the secret a JWT is signed with.
type CodecCodec[E any] struct {
	Secret Secret
}

func (c CodecCodec[E]) String() string { return "codec" }

func CodecWith[T any, E any](value T, _ CodecCodec[E]) T { return value }
