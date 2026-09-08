// Command agy-usage reads the AGY conversation database without requiring AGY,
// Python, protoc, or CGO at runtime. Content is processed locally only as
// necessary to extract usage metadata and is not extracted, retained, or transmitted.
package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"google.golang.org/protobuf/encoding/protowire"
	_ "modernc.org/sqlite"
)

// These paths describe the current AGY step_payload mapping (step 5 is the
// serialized step; 9 is the model response envelope; 33 is the usage message).
// The schema-derived fixture is synthetic, so review this mapping against a
// sanitized captured payload when one becomes independently available.
var (
	usageMessagePath = []int{5, 9, 33}
	inputField       = 1
	cacheReadField   = 2
	cacheWriteField  = 3
	outputField      = 4
)

type result struct {
	Timestamp     string `json:"timestamp"`
	InputTokens   int64  `json:"input_tokens"`
	CacheRead     int64  `json:"cache_read_tokens"`
	CacheCreation int64  `json:"cache_creation_tokens"`
	Model         string `json:"model"`
	Provider      string `json:"provider"`
}

type field struct {
	number protowire.Number
	typ    protowire.Type
	value  []byte
	varint uint64
}

func fields(data []byte) ([]field, error) {
	var out []field
	for len(data) > 0 {
		n, typ, k := protowire.ConsumeTag(data)
		if k < 0 {
			return nil, errors.New("invalid protobuf tag")
		}
		data = data[k:]
		var v []byte
		var x uint64
		var m int
		switch typ {
		case protowire.VarintType:
			x, m = protowire.ConsumeVarint(data)
		case protowire.Fixed32Type:
			_, m = protowire.ConsumeFixed32(data)
		case protowire.Fixed64Type:
			_, m = protowire.ConsumeFixed64(data)
		case protowire.BytesType:
			v, m = protowire.ConsumeBytes(data)
		default:
			m = -1
		}
		if m < 0 {
			return nil, errors.New("invalid protobuf value")
		}
		out = append(out, field{n, typ, append([]byte(nil), v...), x})
		data = data[m:]
	}
	return out, nil
}

func messageAt(data []byte, path []int) ([]byte, error) {
	for _, want := range path {
		fs, err := fields(data)
		if err != nil {
			return nil, err
		}
		var found []byte
		for _, f := range fs {
			if int(f.number) == want && f.typ == protowire.BytesType {
				if found != nil {
					return nil, fmt.Errorf("ambiguous protobuf path field %d", want)
				}
				found = f.value
			}
		}
		if found == nil {
			return nil, fmt.Errorf("missing protobuf path field %d", want)
		}
		data = found
	}
	return data, nil
}

func counter(data []byte, number int) (int64, error) {
	fs, err := fields(data)
	if err != nil {
		return 0, err
	}
	var found *int64
	for _, f := range fs {
		if int(f.number) != number || f.typ != protowire.VarintType {
			continue
		}
		x := int64(f.varint)
		if x < 0 {
			return 0, errors.New("negative usage counter")
		}
		if found != nil {
			return 0, fmt.Errorf("ambiguous usage field %d", number)
		}
		found = &x
	}
	if found == nil {
		return 0, fmt.Errorf("missing usage field %d", number)
	}
	return *found, nil
}

func textAt(data []byte, path []int) string {
	if len(path) == 0 {
		return ""
	}
	msg, err := messageAt(data, path[:len(path)-1])
	if err != nil {
		return ""
	}
	fs, err := fields(msg)
	if err != nil {
		return ""
	}
	for _, f := range fs {
		if int(f.number) == path[len(path)-1] && f.typ == protowire.BytesType && len(f.value) > 0 && len(f.value) < 256 && isText(f.value) {
			return string(f.value)
		}
	}
	return ""
}

func isText(b []byte) bool {
	for _, c := range b {
		if c < 0x20 || c > 0x7e {
			return false
		}
	}
	return true
}

func decodePayload(payload []byte) (result, error) {
	usage, err := messageAt(payload, usageMessagePath)
	if err != nil {
		return result{}, err
	}
	in, err := counter(usage, inputField)
	if err != nil {
		return result{}, err
	}
	read, err := counter(usage, cacheReadField)
	if err != nil {
		return result{}, err
	}
	write, err := counter(usage, cacheWriteField)
	if err != nil {
		return result{}, err
	}
	if _, err = counter(usage, outputField); err != nil {
		return result{}, err
	}
	return result{InputTokens: in, CacheRead: read, CacheCreation: write, Model: textAt(payload, []int{5, 9, 7}), Provider: textAt(payload, []int{5, 9, 8})}, nil
}

func dbURI(path string) string {
	cleaned := filepath.Clean(path)
	// Encode characters that SQLite URI parsing would misinterpret (# ? %).
	var encoded strings.Builder
	for _, b := range []byte(cleaned) {
		switch {
		case b == '#' || b == '?' || b == '%':
			fmt.Fprintf(&encoded, "%%%02X", b)
		default:
			encoded.WriteByte(b)
		}
	}
	return "file:" + encoded.String() + "?mode=ro&_busy_timeout=750"
}

func readDB(path, session string) (result, error) {
	if path == "" || session == "" {
		return result{}, errors.New("missing database or session")
	}
	db, err := sql.Open("sqlite", dbURI(path))
	if err != nil {
		return result{}, err
	}
	defer db.Close()
	if err = db.Ping(); err != nil {
		return result{}, err
	}
	rows, err := db.Query(`SELECT idx, step_payload, metadata FROM steps ORDER BY idx DESC LIMIT 200`)
	if err != nil {
		return result{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var idx int64
		var payload, metadata []byte
		if err := rows.Scan(&idx, &payload, &metadata); err != nil {
			return result{}, err
		}
		if !strings.Contains(string(append(payload, metadata...)), session) {
			continue
		}
		r, err := decodePayload(payload)
		if err != nil {
			continue
		}
		r.Timestamp = timestamp(metadata, payload)
		if r.Timestamp == "" {
			continue
		}
		// Rows are ordered newest-first. The first semantically valid record is
		// the answer; older valid records must not make a current answer
		// ambiguous.
		return r, nil
	}
	if err := rows.Err(); err != nil {
		return result{}, err
	}
	return result{}, errors.New("native usage unavailable")
}

func timestamp(metadata, payload []byte) string {
	// AGY stores protobuf timestamps as seconds/nanoseconds in the first
	// timestamp message of the step metadata. Do not guess from arbitrary ints.
	fs, err := fields(metadata)
	if err != nil {
		return ""
	}
	for _, f := range fs {
		if f.number == 1 && f.typ == protowire.BytesType {
			inner, e := fields(f.value)
			if e != nil {
				continue
			}
			var sec, nano int64
			for _, x := range inner {
				if x.typ != protowire.VarintType {
					continue
				}
				if x.number == 1 {
					sec = int64(x.varint)
				}
				if x.number == 2 {
					nano = int64(x.varint)
				}
			}
			if sec > 0 {
				return time.Unix(sec, nano).UTC().Format(time.RFC3339Nano)
			}
		}
	}
	return ""
}

func main() {
	flag.Usage = func() { fmt.Fprintln(os.Stderr, "usage: agy-usage <db> <session-id>") }
	flag.Parse()
	if flag.NArg() != 2 {
		flag.Usage()
		os.Exit(2)
	}
	r, err := readDB(flag.Arg(0), flag.Arg(1))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(r); err != nil {
		os.Exit(1)
	}
}
