package data

import (
	"io"

	"github.com/pkg/errors"
)

func FetchPartRefs(refs []*PartRef) ([]byte, error) {
	totalLen := 0
	for i := 0; i < len(refs); i++ {
		totalLen += refs[i].NByte
	}

	// Fetch data to local memory
	var out = make([]byte, totalLen)
	inPos := 0
	for i := 0; i < len(refs); i++ {
		bktRef := refs[i]
		parts, err := bktRef.Arr.GetParts()
		if err != nil {
			return nil, errors.Wrapf(err, "Couldn't get partitions from input ref %v", i)
		}
		reader, err := parts[bktRef.PartIdx].GetRangeReader(bktRef.Start, bktRef.Start+bktRef.NByte)
		if err != nil {
			return nil, errors.Wrapf(err, "Couldn't read partition from ref %v", i)
		}

		n, err := io.ReadFull(reader, out[inPos:inPos+bktRef.NByte])
		if err != nil || n != bktRef.NByte {
			return nil, errors.Wrapf(err, "Couldn't read from input ref %v", i)
		}

		inPos += bktRef.NByte
		reader.Close()
	}

	return out, nil
}