package hive

// What a Result holds, and whether it holds it — for the tests that read the
// runtime's answers as a program would.
func okOf[T, E any](r Result[T, E]) (T, bool)  { return r.Ok(), r.IsOk() }
func errOf[T, E any](r Result[T, E]) (E, bool) { return r.Err(), r.IsError() }
