package main

import (
	"testing"

	"google.golang.org/protobuf/encoding/protowire"
)

func nested(number int, value []byte) []byte {
	return protowire.AppendBytes(protowire.AppendTag(nil, protowire.Number(number), protowire.BytesType), value)
}

func varint(number int, value uint64) []byte {
	return protowire.AppendVarint(protowire.AppendTag(nil, protowire.Number(number), protowire.VarintType), value)
}

func fixturePayload() []byte {
	usage := varint(1, 12000)
	usage = append(usage, varint(2, 48900)...)
	usage = append(usage, varint(3, 3000)...)
	usage = append(usage, varint(4, 318)...)
	response := nested(33, usage)
	response = append(response, nested(7, []byte("Gemini 3.8 Flash"))...)
	response = append(response, nested(8, []byte("antigravity"))...)
	return nested(5, nested(9, response))
}

func TestDecodePayload(t *testing.T) {
	r, err := decodePayload(fixturePayload())
	if err != nil {
		t.Fatal(err)
	}
	if r.InputTokens != 12000 || r.CacheRead != 48900 || r.CacheCreation != 3000 {
		t.Fatalf("unexpected counters: %+v", r)
	}
	if r.Model != "Gemini 3.8 Flash" || r.Provider != "antigravity" {
		t.Fatalf("unexpected identity: %+v", r)
	}
}

func TestDecodePayloadFailsClosed(t *testing.T) {
	p := fixturePayload()[:len(fixturePayload())-1]
	if _, err := decodePayload(p); err == nil {
		t.Fatal("truncated protobuf was accepted")
	}

	usage := varint(1, 1)
	usage = append(usage, varint(2, 2)...)
	usage = append(usage, varint(3, 3)...)
	usage = append(usage, varint(1, 4)...)
	p = nested(5, nested(9, nested(33, usage)))
	if _, err := decodePayload(p); err == nil {
		t.Fatal("ambiguous counter was accepted")
	}
}
