//go:build darwin && cgo

package automation

/*
#cgo LDFLAGS: -lsqlite3

#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	char *schema;
	char *table;
	sqlite3_int64 row;
} swipt_change;

typedef struct {
	swipt_change *items;
	size_t count;
	size_t capacity;
} swipt_changes;

static void swipt_record_change(void *context, int operation, const char *schema, const char *table, sqlite3_int64 row) {
	swipt_changes *changes = context;
	if (changes->count == changes->capacity) {
		size_t capacity = changes->capacity == 0 ? 16 : changes->capacity * 2;
		swipt_change *items = realloc(changes->items, capacity * sizeof(swipt_change));
		if (items == NULL) {
			return;
		}
		changes->items = items;
		changes->capacity = capacity;
	}
	changes->items[changes->count++] = (swipt_change){strdup(schema), strdup(table), row};
}

static void swipt_watch_changes(sqlite3 *db, swipt_changes *changes) {
	sqlite3_update_hook(db, swipt_record_change, changes);
}

static void swipt_clear_changes(swipt_changes *changes) {
	for (size_t index = 0; index < changes->count; index++) {
		free(changes->items[index].schema);
		free(changes->items[index].table);
	}
	changes->count = 0;
}

static void swipt_free_changes(swipt_changes *changes) {
	swipt_clear_changes(changes);
	free(changes->items);
	free(changes);
}

static int swipt_bind_text(sqlite3_stmt *statement, int index, const char *text, int length) {
	return sqlite3_bind_text(statement, index, length == 0 ? "" : text, length, SQLITE_TRANSIENT);
}

static int swipt_bind_blob(sqlite3_stmt *statement, int index, const void *data, int length) {
	if (length == 0) {
		return sqlite3_bind_zeroblob(statement, index, 0);
	}
	return sqlite3_bind_blob(statement, index, data, length, SQLITE_TRANSIENT);
}
*/
import "C"

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"maps"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"unsafe"

	E "github.com/sagernet/sing/common/exceptions"
)

type DatabaseChange struct {
	Swiplet  string
	Database string
	Path     string
	Table    string
	RowID    int64
}

type databaseWatcher struct {
	swiplet string
	publish func(DatabaseChange)
}

type databaseStore struct {
	access    sync.Mutex
	next      int
	databases map[int]*database
	watchers  map[*databaseWatcher]struct{}
}

type database struct {
	access     sync.Mutex
	client     any
	swiplet    string
	path       string
	conn       *C.sqlite3
	changes    *C.swipt_changes
	next       int
	statements map[int]*C.sqlite3_stmt
}

type databaseRequest struct {
	Op        string          `json:"op"`
	Handle    int             `json:"handle"`
	Statement int             `json:"statement"`
	Path      string          `json:"path"`
	Changes   bool            `json:"changes"`
	SQL       string          `json:"sql"`
	Params    json.RawMessage `json:"params"`
}

type databaseRun struct {
	Changes         int64    `json:"changes"`
	LastInsertRowID int64    `json:"lastInsertRowId"`
	Columns         []string `json:"columns"`
	Rows            [][]any  `json:"rows"`
}

const (
	memoryDatabase = ":memory:"
	statementLimit = 256
)

var errDatabaseClosed = E.Cause1(ErrInvalid, E.New("the database is closed"))

func newDatabaseStore() databaseStore {
	return databaseStore{databases: make(map[int]*database), watchers: make(map[*databaseWatcher]struct{})}
}

func (h *Host) SQLite(client any, swiplet string, request []byte) (any, error) {
	var call databaseRequest
	if err := json.Unmarshal(request, &call); err != nil {
		return nil, E.Cause1(ErrInvalid, E.Cause(err, "decode the database request"))
	}
	switch call.Op {
	case "open":
		return h.openDatabase(client, swiplet, call)
	case "delete":
		return nil, h.deleteDatabase(swiplet, call.Path)
	}
	h.databases.access.Lock()
	db, found := h.databases.databases[call.Handle]
	if found && (db.client != client || db.swiplet != swiplet) {
		found = false
	}
	if found && call.Op == "close" {
		delete(h.databases.databases, call.Handle)
	}
	h.databases.access.Unlock()
	if !found {
		return nil, errDatabaseClosed
	}
	if call.Op == "close" {
		db.close()
		return nil, nil
	}
	db.access.Lock()
	result, err := db.serve(call)
	changes := db.takeChanges()
	db.access.Unlock()
	h.publishChanges(swiplet, changes)
	return result, err
}

func (h *Host) dataDirectory(swiplet string) (string, error) {
	if swiplet == REPLDirectory {
		return filepath.Join(h.options.Directory, REPLDirectory, DataFolder), nil
	}
	found, err := h.Swiplet(swiplet)
	if err != nil {
		return "", err
	}
	return filepath.Join(found.Directory, DataFolder), nil
}

func (h *Host) databasePath(swiplet, name string) (string, error) {
	if name == memoryDatabase {
		return name, nil
	}
	cleaned, err := cleanName(name)
	if err != nil {
		return "", err
	}
	if cleaned == "." {
		return "", E.Cause1(ErrInvalid, E.New("the database needs a file name"))
	}
	directory, err := h.dataDirectory(swiplet)
	if err != nil {
		return "", err
	}
	return filepath.Join(directory, cleaned), nil
}

func (h *Host) openDatabase(client any, swiplet string, call databaseRequest) (any, error) {
	path, err := h.databasePath(swiplet, call.Path)
	if err != nil {
		return nil, err
	}
	if path != memoryDatabase {
		if err = os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, err
		}
	}
	name := C.CString(path)
	defer C.free(unsafe.Pointer(name))
	var conn *C.sqlite3
	code := C.sqlite3_open_v2(name, &conn, C.SQLITE_OPEN_READWRITE|C.SQLITE_OPEN_CREATE|C.SQLITE_OPEN_NOMUTEX, nil)
	db := &database{client: client, swiplet: swiplet, path: path, conn: conn, statements: make(map[int]*C.sqlite3_stmt)}
	if code != C.SQLITE_OK {
		err = db.failure(code)
		db.close()
		return nil, E.Cause(err, "open ", strconv.Quote(call.Path))
	}
	C.sqlite3_busy_timeout(conn, 5000)
	if path != memoryDatabase {
		if err = db.exec("PRAGMA journal_mode = WAL"); err != nil {
			db.close()
			return nil, E.Cause(err, "open ", strconv.Quote(call.Path))
		}
	}
	if call.Changes {
		db.changes = (*C.swipt_changes)(C.calloc(1, C.sizeof_swipt_changes))
		C.swipt_watch_changes(conn, db.changes)
	}
	h.databases.access.Lock()
	h.databases.next++
	handle := h.databases.next
	h.databases.databases[handle] = db
	h.databases.access.Unlock()
	return map[string]any{"handle": handle, "path": path}, nil
}

func (h *Host) deleteDatabase(swiplet, name string) error {
	if name == memoryDatabase {
		return E.Cause1(ErrInvalid, E.New("a memory database cannot be deleted"))
	}
	path, err := h.databasePath(swiplet, name)
	if err != nil {
		return err
	}
	h.databases.access.Lock()
	for _, db := range h.databases.databases {
		if db.path == path {
			h.databases.access.Unlock()
			return E.Cause1(ErrInvalid, E.New("the database ", strconv.Quote(name), " is open"))
		}
	}
	h.databases.access.Unlock()
	for _, suffix := range []string{"", "-wal", "-shm", "-journal"} {
		if removeErr := os.Remove(path + suffix); !errors.Is(removeErr, os.ErrNotExist) {
			err = E.Errors(err, removeErr)
		}
	}
	return err
}

func (h *Host) CloseDatabases(client any, swiplet string) {
	h.databases.access.Lock()
	var closing []*database
	for handle, db := range h.databases.databases {
		if (client == nil || db.client == client) && (swiplet == "" || db.swiplet == swiplet) {
			closing = append(closing, db)
			delete(h.databases.databases, handle)
		}
	}
	h.databases.access.Unlock()
	for _, db := range closing {
		db.close()
	}
}

func (h *Host) WatchDatabases(ctx context.Context, swiplet string, publish func(DatabaseChange)) {
	watcher := &databaseWatcher{swiplet: swiplet, publish: publish}
	h.databases.access.Lock()
	h.databases.watchers[watcher] = struct{}{}
	h.databases.access.Unlock()
	<-ctx.Done()
	h.databases.access.Lock()
	delete(h.databases.watchers, watcher)
	h.databases.access.Unlock()
}

func (h *Host) publishChanges(swiplet string, changes []DatabaseChange) {
	if len(changes) == 0 {
		return
	}
	h.databases.access.Lock()
	var watchers []*databaseWatcher
	for watcher := range h.databases.watchers {
		if watcher.swiplet == "" || watcher.swiplet == swiplet {
			watchers = append(watchers, watcher)
		}
	}
	h.databases.access.Unlock()
	for _, watcher := range watchers {
		for _, change := range changes {
			watcher.publish(change)
		}
	}
}

func (db *database) close() {
	db.access.Lock()
	defer db.access.Unlock()
	for _, stmt := range db.statements {
		C.sqlite3_finalize(stmt)
	}
	clear(db.statements)
	C.sqlite3_close_v2(db.conn)
	db.conn = nil
	if db.changes != nil {
		C.swipt_free_changes(db.changes)
		db.changes = nil
	}
}

func (db *database) failure(code C.int) error {
	message := C.GoString(C.sqlite3_errstr(code))
	if db.conn != nil {
		message = C.GoString(C.sqlite3_errmsg(db.conn))
	}
	return E.Cause1(ErrInvalid, E.New(message))
}

func (db *database) serve(call databaseRequest) (any, error) {
	if db.conn == nil {
		return nil, errDatabaseClosed
	}
	switch call.Op {
	case "exec":
		return nil, db.exec(call.SQL)
	case "prepare":
		return db.prepare(call.SQL)
	case "finalize":
		if stmt, found := db.statements[call.Statement]; found {
			delete(db.statements, call.Statement)
			C.sqlite3_finalize(stmt)
		}
		return nil, nil
	case "run":
		stmt, found := db.statements[call.Statement]
		if !found {
			return nil, E.Cause1(ErrInvalid, E.New("the statement is finalized"))
		}
		return db.run(stmt, call.Params)
	case "autocommit":
		return C.sqlite3_get_autocommit(db.conn) != 0, nil
	}
	return nil, E.Cause1(ErrInvalid, E.New("unknown database operation ", strconv.Quote(call.Op)))
}

func (db *database) exec(source string) error {
	text := C.CString(source)
	defer C.free(unsafe.Pointer(text))
	if code := C.sqlite3_exec(db.conn, text, nil, nil, nil); code != C.SQLITE_OK {
		return db.failure(code)
	}
	return nil
}

func (db *database) prepare(source string) (any, error) {
	if source == "" {
		return nil, E.Cause1(ErrInvalid, E.New("the SQL has no statement"))
	}
	var stmt *C.sqlite3_stmt
	code := C.sqlite3_prepare_v3(db.conn, (*C.char)(unsafe.Pointer(unsafe.StringData(source))), C.int(len(source)), C.SQLITE_PREPARE_PERSISTENT, &stmt, nil)
	if code != C.SQLITE_OK {
		return nil, db.failure(code)
	}
	if stmt == nil {
		return nil, E.Cause1(ErrInvalid, E.New("the SQL has no statement"))
	}
	if len(db.statements) >= statementLimit {
		oldest := slices.Min(slices.Collect(maps.Keys(db.statements)))
		C.sqlite3_finalize(db.statements[oldest])
		delete(db.statements, oldest)
	}
	db.next++
	db.statements[db.next] = stmt
	return map[string]any{"statement": db.next, "columns": columnNames(stmt)}, nil
}

func (db *database) run(stmt *C.sqlite3_stmt, params json.RawMessage) (any, error) {
	C.sqlite3_reset(stmt)
	C.sqlite3_clear_bindings(stmt)
	if err := db.bind(stmt, params); err != nil {
		return nil, err
	}
	out := databaseRun{Columns: columnNames(stmt), Rows: [][]any{}}
	for {
		code := C.sqlite3_step(stmt)
		if code == C.SQLITE_DONE {
			break
		}
		if code != C.SQLITE_ROW {
			err := db.failure(code)
			C.sqlite3_reset(stmt)
			return nil, err
		}
		row := make([]any, len(out.Columns))
		for index := range row {
			row[index] = columnValue(stmt, C.int(index))
		}
		out.Rows = append(out.Rows, row)
	}
	C.sqlite3_reset(stmt)
	out.Changes = int64(C.sqlite3_changes64(db.conn))
	out.LastInsertRowID = int64(C.sqlite3_last_insert_rowid(db.conn))
	return out, nil
}

func (db *database) bind(stmt *C.sqlite3_stmt, encoded json.RawMessage) error {
	if len(encoded) == 0 || string(encoded) == "null" {
		return nil
	}
	var list []json.RawMessage
	if json.Unmarshal(encoded, &list) == nil {
		for index, item := range list {
			if err := db.bindValue(stmt, C.int(index+1), item); err != nil {
				return err
			}
		}
		return nil
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &object); err != nil {
		return E.Cause1(ErrInvalid, E.New("the parameters must be an array or an object"))
	}
	for key, item := range object {
		index := parameterIndex(stmt, key)
		if index == 0 {
			continue
		}
		if err := db.bindValue(stmt, index, item); err != nil {
			return err
		}
	}
	return nil
}

func parameterIndex(stmt *C.sqlite3_stmt, key string) C.int {
	names := []string{key}
	if key == "" || !strings.ContainsRune("$:@?", rune(key[0])) {
		names = []string{"$" + key, ":" + key, "@" + key}
	}
	for _, name := range names {
		text := C.CString(name)
		index := C.sqlite3_bind_parameter_index(stmt, text)
		C.free(unsafe.Pointer(text))
		if index != 0 {
			return index
		}
	}
	return 0
}

func (db *database) bindValue(stmt *C.sqlite3_stmt, index C.int, item json.RawMessage) error {
	decoder := json.NewDecoder(strings.NewReader(string(item)))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return E.Cause1(ErrInvalid, E.Cause(err, "decode a parameter"))
	}
	var code C.int
	switch v := value.(type) {
	case nil:
		code = C.sqlite3_bind_null(stmt, index)
	case bool:
		var integer C.sqlite3_int64
		if v {
			integer = 1
		}
		code = C.sqlite3_bind_int64(stmt, index, integer)
	case string:
		code = C.swipt_bind_text(stmt, index, (*C.char)(unsafe.Pointer(unsafe.StringData(v))), C.int(len(v)))
	case json.Number:
		if integer, err := v.Int64(); err == nil {
			code = C.sqlite3_bind_int64(stmt, index, C.sqlite3_int64(integer))
		} else if float, err := v.Float64(); err == nil {
			code = C.sqlite3_bind_double(stmt, index, C.double(float))
		} else {
			return E.Cause1(ErrInvalid, E.New("the number ", v.String(), " is out of range"))
		}
	case map[string]any:
		if encoded, ok := v["$b"].(string); ok && len(v) == 1 {
			data, err := base64.StdEncoding.DecodeString(encoded)
			if err != nil {
				return E.Cause1(ErrInvalid, E.Cause(err, "decode a blob parameter"))
			}
			code = C.swipt_bind_blob(stmt, index, unsafe.Pointer(unsafe.SliceData(data)), C.int(len(data)))
		} else if decimal, ok := v["$i"].(string); ok && len(v) == 1 {
			integer, err := strconv.ParseInt(decimal, 10, 64)
			if err != nil {
				return E.Cause1(ErrInvalid, E.New("the bigint ", decimal, " is out of the 64-bit range"))
			}
			code = C.sqlite3_bind_int64(stmt, index, C.sqlite3_int64(integer))
		} else {
			return E.Cause1(ErrInvalid, E.New("a parameter must be null, a number, a bigint, a string, a boolean or a Uint8Array"))
		}
	default:
		return E.Cause1(ErrInvalid, E.New("a parameter must be null, a number, a bigint, a string, a boolean or a Uint8Array"))
	}
	if code != C.SQLITE_OK {
		return db.failure(code)
	}
	return nil
}

func (db *database) takeChanges() []DatabaseChange {
	if db.changes == nil || db.changes.count == 0 {
		return nil
	}
	items := unsafe.Slice(db.changes.items, db.changes.count)
	changes := make([]DatabaseChange, len(items))
	for index, item := range items {
		changes[index] = DatabaseChange{Swiplet: db.swiplet, Database: C.GoString(item.schema), Path: db.path, Table: C.GoString(item.table), RowID: int64(item.row)}
	}
	C.swipt_clear_changes(db.changes)
	return changes
}

func columnNames(stmt *C.sqlite3_stmt) []string {
	names := make([]string, int(C.sqlite3_column_count(stmt)))
	for index := range names {
		names[index] = C.GoString(C.sqlite3_column_name(stmt, C.int(index)))
	}
	return names
}

func columnValue(stmt *C.sqlite3_stmt, index C.int) any {
	switch C.sqlite3_column_type(stmt, index) {
	case C.SQLITE_INTEGER:
		return int64(C.sqlite3_column_int64(stmt, index))
	case C.SQLITE_FLOAT:
		value := float64(C.sqlite3_column_double(stmt, index))
		if math.IsInf(value, 0) {
			return nil
		}
		return value
	case C.SQLITE_TEXT:
		text := C.sqlite3_column_text(stmt, index)
		return C.GoStringN((*C.char)(unsafe.Pointer(text)), C.sqlite3_column_bytes(stmt, index))
	case C.SQLITE_BLOB:
		data := C.sqlite3_column_blob(stmt, index)
		return map[string]string{"$b": base64.StdEncoding.EncodeToString(C.GoBytes(data, C.sqlite3_column_bytes(stmt, index)))}
	}
	return nil
}
