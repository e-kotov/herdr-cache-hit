package main

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"

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

func fixtureMetadata(sec int64, nano int64, session string) []byte {
	ts := varint(1, uint64(sec))
	ts = append(ts, varint(2, uint64(nano))...)
	meta := nested(1, ts)
	if session != "" {
		meta = append(meta, nested(2, []byte(session))...)
	}
	return meta
}

func customPayload(input, read, write int64, model, provider string) []byte {
	usage := varint(1, uint64(input))
	usage = append(usage, varint(2, uint64(read))...)
	usage = append(usage, varint(3, uint64(write))...)
	usage = append(usage, varint(4, 100)...)
	response := nested(33, usage)
	response = append(response, nested(7, []byte(model))...)
	response = append(response, nested(8, []byte(provider))...)
	return nested(5, nested(9, response))
}

func TestReadDB(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "steps_test.db")

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("failed to open test db: %v", err)
	}
	defer db.Close()

	_, err = db.Exec("CREATE TABLE `steps` (`idx` integer, `step_type` integer NOT NULL DEFAULT 0, `status` integer NOT NULL DEFAULT 0, `has_subtrajectory` numeric NOT NULL DEFAULT false, `metadata` blob, `error_details` blob, `permissions` blob, `task_details` blob, `render_info` blob, `step_payload` blob, `step_format` integer NOT NULL DEFAULT 0, PRIMARY KEY (`idx`))")
	if err != nil {
		t.Fatalf("failed to create steps table: %v", err)
	}

	// 1. Unrelated session row (idx 1)
	p1 := customPayload(100, 50, 20, "Gemini", "antigravity")
	m1 := fixtureMetadata(1700000000, 0, "sess-unrelated")
	_, err = db.Exec(`INSERT INTO steps (idx, step_type, status, step_payload, metadata) VALUES (?, 0, 3, ?, ?)`, 1, p1, m1)
	if err != nil {
		t.Fatal(err)
	}

	// 2. Target session older valid row (idx 2)
	p2 := customPayload(500, 200, 50, "Gemini Old", "antigravity")
	m2 := fixtureMetadata(1700000100, 0, "sess-target")
	_, err = db.Exec(`INSERT INTO steps (idx, step_type, status, step_payload, metadata) VALUES (?, 0, 3, ?, ?)`, 2, p2, m2)
	if err != nil {
		t.Fatal(err)
	}

	// 3. Target session newer malformed row (idx 3) - should be skipped
	p3 := []byte("corrupt-payload")
	m3 := fixtureMetadata(1700000200, 0, "sess-target")
	_, err = db.Exec(`INSERT INTO steps (idx, step_type, status, step_payload, metadata) VALUES (?, 0, 3, ?, ?)`, 3, p3, m3)
	if err != nil {
		t.Fatal(err)
	}

	// 4. Target session newest valid row (idx 4)
	p4 := customPayload(12000, 48900, 3000, "Gemini 3.8 Flash", "antigravity")
	m4 := fixtureMetadata(1700000300, 0, "sess-target")
	_, err = db.Exec(`INSERT INTO steps (idx, step_type, status, step_payload, metadata) VALUES (?, 0, 3, ?, ?)`, 4, p4, m4)
	if err != nil {
		t.Fatal(err)
	}

	// Test readDB selects newest valid record for target session
	res, err := readDB(dbPath, "sess-target")
	if err != nil {
		t.Fatalf("readDB failed for sess-target: %v", err)
	}
	if res.InputTokens != 12000 || res.CacheRead != 48900 || res.CacheCreation != 3000 {
		t.Fatalf("expected newest counters, got: %+v", res)
	}
	if res.Model != "Gemini 3.8 Flash" || res.Provider != "antigravity" {
		t.Fatalf("expected Gemini 3.8 Flash, got: %+v", res)
	}
	expectedTS := time.Unix(1700000300, 0).UTC().Format(time.RFC3339Nano)
	if res.Timestamp != expectedTS {
		t.Fatalf("expected timestamp %s, got %s", expectedTS, res.Timestamp)
	}

	// Test session isolation: unrelated session returns its own record
	resOther, err := readDB(dbPath, "sess-unrelated")
	if err != nil {
		t.Fatalf("readDB failed for sess-unrelated: %v", err)
	}
	if resOther.InputTokens != 100 || resOther.CacheRead != 50 {
		t.Fatalf("expected sess-unrelated counters, got: %+v", resOther)
	}

	// Test non-existent session fails
	if _, err := readDB(dbPath, "sess-missing"); err == nil {
		t.Fatal("expected error for missing session, got nil")
	}

	// Test missing arguments
	if _, err := readDB("", "sess-target"); err == nil {
		t.Fatal("expected error for empty db path, got nil")
	}
	if _, err := readDB(dbPath, ""); err == nil {
		t.Fatal("expected error for empty session id, got nil")
	}
}

func TestReadDBSchemaDerivedSyntheticFixture(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "schema-derived.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	fixture, err := os.ReadFile(filepath.Join("testdata", "schema-derived-steps.sql"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(string(fixture)); err != nil {
		t.Fatal(err)
	}
	if err = db.Close(); err != nil {
		t.Fatal(err)
	}

	r, err := readDB(dbPath, "synthetic-session")
	if err != nil {
		t.Fatal(err)
	}
	if r.InputTokens != 12000 || r.CacheRead != 48900 || r.CacheCreation != 3000 {
		t.Fatalf("unexpected synthetic fixture counters: %+v", r)
	}
	if r.Model != "Gemini Synthetic" || r.Provider != "antigravity" {
		t.Fatalf("unexpected synthetic fixture identity: %+v", r)
	}
	if r.Timestamp != time.Unix(1700000300, 0).UTC().Format(time.RFC3339Nano) {
		t.Fatalf("unexpected synthetic fixture timestamp: %s", r.Timestamp)
	}
}

func TestReadDBNonexistent(t *testing.T) {
	_, err := readDB("/nonexistent/path/to/database.db", "any-session")
	if err == nil {
		t.Fatal("expected error for nonexistent database")
	}
}

func TestReadDBCorrupt(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "corrupt.db")
	if err := os.WriteFile(path, []byte("not a database"), 0644); err != nil {
		t.Fatal(err)
	}
	_, err := readDB(path, "any-session")
	if err == nil {
		t.Fatal("expected error for corrupt database")
	}
}
