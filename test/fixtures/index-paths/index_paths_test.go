package indexpaths

import "testing"

func TestNestedIndexPaths(t *testing.T) {
	chain := lsNamed("Chain")
	inner := lsNamed("lawspec::structural::record::inner")
	outer := lsNamed("lawspec::structural::record::outer")
	wrapper := lsNamed("Wrapper")
	field := func(name string, ty lawSpecTypeRef) lawSpecFieldSchema {
		return lawSpecFieldSchema{name: name, typeRef: ty}
	}
	ctor := func(tag string, fields []lawSpecFieldSchema, indices ...string) lawSpecConstructorSchema {
		return lawSpecConstructorSchema{tag: tag, fields: fields, indices: indices}
	}
	schema := lsNewSchema([]lawSpecDataSchema{
		{name: "Chain", constructors: []lawSpecConstructorSchema{ctor("Stop", nil, "c0", "c10"), ctor("Next", []lawSpecFieldSchema{field("tail", chain)}, "+ f0 c1", "+ f0.1 c1")}},
		{name: inner.name, constructors: []lawSpecConstructorSchema{ctor("Inner", []lawSpecFieldSchema{field("rest", chain)})}},
		{name: outer.name, constructors: []lawSpecConstructorSchema{ctor("Outer", []lawSpecFieldSchema{field("child", inner), field("sibling", chain)})}},
		{name: "Wrapper", constructors: []lawSpecConstructorSchema{ctor("Wrap", []lawSpecFieldSchema{field("payload", outer)}, "p0/0/0.0", "p0/0/0.1", "== p0/0/0.1 + p0/1.0 c10", "== p0/0/0.0 p0/1.0", ">= p0/0/0.0 c1")}},
	}, nil)
	value := func(ty lawSpecTypeRef, tag string, fields ...LawSpecValue) LawSpecValue {
		return LawSpecValue{ty.key(), lawSpecData{tag, fields}}
	}
	stop := value(chain, "Stop")
	one := value(chain, "Next", stop)
	two := value(chain, "Next", one)
	wrap := func(left, right LawSpecValue) LawSpecValue {
		return value(wrapper, "Wrap", value(outer, "Outer", value(inner, "Inner", left), right))
	}
	for _, bits := range []int{32, 64} {
		good := wrap(two, two)
		schema.validate(wrapper, good, bits)
		if schema.indexOf(wrapper, good, 0).Int64() != 2 || schema.indexOf(wrapper, good, 1).Int64() != 12 {
			t.Fatal("wrong path index")
		}
		for _, bad := range []LawSpecValue{wrap(two, one), wrap(stop, stop)} {
			if schema.accepts(wrapper, bad, bits) {
				t.Fatal("accepted mismatched or underflowing indices")
			}
		}
	}
}
