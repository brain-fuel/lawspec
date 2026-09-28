// Compare parsed Go syntax without positions or comments, preserving literals.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"reflect"
)

func tree(path string) string {
	file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.SkipObjectResolution)
	if err != nil {
		panic(err)
	}
	var result bytes.Buffer
	filter := func(name string, value reflect.Value) bool {
		return value.Type() != reflect.TypeFor[token.Pos]()
	}
	if err := ast.Fprint(&result, nil, file, filter); err != nil {
		panic(err)
	}
	return result.String()
}

func main() {
	var pairs []struct{ Readable, Compact string }
	if err := json.NewDecoder(os.Stdin).Decode(&pairs); err != nil {
		panic(err)
	}
	for _, pair := range pairs {
		if tree(pair.Readable) != tree(pair.Compact) {
			panic("Go syntax-tree mismatch: " + pair.Readable + " / " + pair.Compact)
		}
	}
	fmt.Printf("%d Go artifacts have identical readable/compact syntax trees\n", len(pairs))
}
