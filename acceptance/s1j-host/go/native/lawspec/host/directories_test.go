package host

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCreateDirectoriesReportsFileConflict(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "file")
	if err := os.WriteFile(file, []byte("contents"), 0600); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if recover() == nil {
			t.Fatal("creating parents through a regular file must fail")
		}
	}()
	(&FileSystemHandler{}).CreateDirectories(filepath.Join(file, "child"))
}
