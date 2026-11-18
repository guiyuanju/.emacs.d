package usage

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"syscall"
)

func fileIdentity(info os.FileInfo) string {
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		return fmt.Sprintf("%d:%d", stat.Dev, stat.Ino)
	}
	return ""
}

func fingerprint(f *os.File, offset int64) (string, string, error) {
	n := min(offset, 256)
	prefix, anchor := make([]byte, n), make([]byte, n)
	if _, err := f.ReadAt(prefix, 0); err != nil {
		return "", "", err
	}
	if _, err := f.ReadAt(anchor, offset-n); err != nil {
		return "", "", err
	}
	a, b := sha256.Sum256(prefix), sha256.Sum256(anchor)
	return hex.EncodeToString(a[:]), hex.EncodeToString(b[:]), nil
}

func readLogLine(reader *bufio.Reader) ([]byte, error) {
	line := make([]byte, 0, 4096)
	for {
		part, err := reader.ReadSlice('\n')
		if len(line)+len(part) > 64<<20 {
			return nil, errors.New("usage: log record exceeds 64 MiB")
		}
		line = append(line, part...)
		if err == bufio.ErrBufferFull {
			continue
		}
		return line, err
	}
}

func (l *Ledger) importFile(ctx context.Context, path, provider string, resolve func(string) string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	fs, err := l.fileState(ctx, path)
	if err != nil {
		return err
	}
	identity := fileIdentity(info)
	reset := info.Size() < fs.Size || fs.Offset > info.Size() ||
		(fs.Identity != "" && fs.Identity != identity) ||
		(fs.Size == info.Size() && fs.Mtime != info.ModTime().UnixNano())
	if !reset && fs.Prefix != "" {
		prefix, anchor, err := fingerprint(f, fs.Offset)
		if err != nil {
			return err
		}
		reset = prefix != fs.Prefix || anchor != fs.Anchor
	}
	if reset {
		fs = fileState{}
	}
	if !reset && fs.Size == info.Size() && fs.Mtime == info.ModTime().UnixNano() && fs.Prefix != "" {
		if fs.Invalid {
			return errors.New("usage: some log records were invalid")
		}
		return nil
	}
	snapshotPrefix, snapshotTail, err := fingerprint(f, info.Size())
	if err != nil {
		return err
	}
	if _, err = f.Seek(fs.Offset, io.SeekStart); err != nil {
		return err
	}
	reader := bufio.NewReaderSize(io.LimitReader(f, info.Size()-fs.Offset), 64<<10)
	bad := fs.Invalid
	var pending []Event
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		line, err := readLogLine(reader)
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		fs.Offset += int64(len(line))
		var r logRecord
		if err := json.Unmarshal(line, &r); err != nil {
			bad = true
			continue
		}
		e, ok, err := parseRecord(provider, &fs, r)
		if err != nil {
			bad = true
			continue
		}
		if ok {
			e.Project = resolve(e.Root)
			pending = append(pending, e)
		}
	}
	prefix, tail, err := fingerprint(f, info.Size())
	if err != nil {
		return err
	}
	if prefix != snapshotPrefix || tail != snapshotTail {
		return errors.New("usage: source changed during import")
	}
	fs.Identity = identity
	fs.Prefix, fs.Anchor, err = fingerprint(f, fs.Offset)
	if err != nil {
		return err
	}
	fs.Invalid, fs.Size, fs.Mtime = bad, info.Size(), info.ModTime().UnixNano()
	if err := l.writeBatch(ctx, pending, path, &fs); err != nil {
		return err
	}
	if bad {
		return errors.New("usage: some log records were invalid")
	}
	return nil
}
