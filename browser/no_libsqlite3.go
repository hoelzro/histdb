//go:build !libsqlite3

package main

func init() {
	panic("Sorry, you need to build me with -tags libsqlite3")
}
