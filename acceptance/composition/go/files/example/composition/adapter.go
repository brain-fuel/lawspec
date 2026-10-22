// User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
// share the case's Store.
package composition

// logStore is an in-memory log store: each log's records, newest last.
type logStore struct {
	logs map[string][]string
	open bool
}

// OpenStore implements openStore :: (Unit -> example.composition::type::Store).
func OpenStore(value0 LawSpecValue) any {
	return &logStore{logs: map[string][]string{}, open: true}
}

// CloseStore implements closeStore :: (example.composition::type::Store -> Unit).
func CloseStore(value0 any) {
	value0.(*logStore).open = false
}

// LogsHandler is the native handler of Logs: create, append.
type LogsHandler struct {
	Resource any
}

// NewLogsHandler makes the native handler the generated tests use.
func NewLogsHandler(resource any) Logs {
	return &LogsHandler{Resource: resource}
}

func (handler *LogsHandler) Create(value0 string) {
	handler.Resource.(*logStore).logs[value0] = []string{}
}

func (handler *LogsHandler) Append(value0 string, value1 string) int64 {
	store := handler.Resource.(*logStore)
	records, ok := store.logs[value0]
	if !ok {
		panic(LawSpecFail{Value: ProblemUnknownLog{}})
	}
	if value1 == "" {
		panic(LawSpecFail{Value: ProblemEmptyRecord{}})
	}
	store.logs[value0] = append(records, value1)
	return int64(len(records))
}

// ReaderHandler is the native handler of Reader: size.
type ReaderHandler struct {
	Resource any
}

// NewReaderHandler makes the native handler the generated tests use.
func NewReaderHandler(resource any) Reader {
	return &ReaderHandler{Resource: resource}
}

func (handler *ReaderHandler) Size(value0 string) LawSpecMaybe[int64] {
	records, ok := handler.Resource.(*logStore).logs[value0]
	if !ok {
		return LawSpecAbsent[int64]()
	}
	return LawSpecPresent(int64(len(records)))
}

// WriterHandler is the native handler of Writer: write, lastOffset.
type WriterHandler struct {
	Resource any
	last     LawSpecMaybe[int64]
}

// NewWriterHandler makes the native handler the generated tests use.
func NewWriterHandler(resource any) Writer {
	return &WriterHandler{Resource: resource}
}

func (handler *WriterHandler) Write(value0 string, value1 string) bool {
	store := handler.Resource.(*logStore)
	records, ok := store.logs[value0]
	if !ok || value1 == "" {
		return false
	}
	store.logs[value0] = append(records, value1)
	handler.last = LawSpecPresent(int64(len(records)))
	return true
}

func (handler *WriterHandler) LastOffset() LawSpecMaybe[int64] {
	return handler.last
}
