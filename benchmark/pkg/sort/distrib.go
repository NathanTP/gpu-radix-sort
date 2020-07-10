package sort

import (
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"path/filepath"
	"sync"

	"github.com/nathantp/gpu-radix-sort/benchmark/pkg/data"
	"github.com/nathantp/gpu-radix-sort/benchmark/pkg/faas"
	"github.com/pkg/errors"
	"github.com/serverlessresearch/srk/pkg/srkmgr"
)

type ArrayFactory func(name string, nbucket int) (data.DistribArray, error)

// Read InBkts in order and sort by the radix of width width and starting at
// offset Returns a distributed array (generated by 'factory') with one part
// per unique radix value. 'factory' should generate a unique name for this worker.
type DistribWorker func(inBkts []*data.PartRef, offset int, width int, factory ArrayFactory) (data.DistribArray, error)

// Returns a DistribWorker that uses mgr to sort via FaaS
func InitFaasWorker(mgr *srkmgr.SrkManager) DistribWorker {
	return func(inBkts []*data.PartRef,
		offset int, width int,
		factory ArrayFactory) (data.DistribArray, error) {

		var err error

		nBucket := 1 << width

		faasRefs := make([]*faas.FaasFilePartRef, len(inBkts))
		for i, bktRef := range inBkts {
			faasRefs[i], err = faas.FilePartRefToFaas(bktRef)
		}

		// Generate output array on host side to avoid permissions errors from Docker
		outArr, err := factory("output", nBucket)
		if err != nil {
			return nil, errors.Wrap(err, "Could not allocate output")
		}

		fileArr, ok := outArr.(*data.FileDistribArray)
		if !ok {
			return nil, fmt.Errorf("Unsupported DistribArray type %T: Only FileRefPart's are supported", outArr)
		}

		faasArg := &faas.FaasArg{
			Offset:  offset,
			Width:   width,
			ArrType: "file",
			Input:   faasRefs,
			Output:  filepath.Base(fileArr.RootPath),
		}

		err = faas.InvokeFaasSort(mgr, faasArg)
		if err != nil {
			return nil, errors.Wrap(err, "FaaS sort failure")
		}

		return outArr, nil
	}
}

func LocalDistribWorker(inBkts []*data.PartRef, offset int, width int, factory ArrayFactory) (data.DistribArray, error) {
	var err error

	totalLen := 0
	for i := 0; i < len(inBkts); i++ {
		totalLen += inBkts[i].NByte
	}
	nInt := totalLen / 4

	// Fetch data to local memory
	var inInts = make([]uint32, nInt)
	inPos := 0
	for i := 0; i < len(inBkts); i++ {
		bktRef := inBkts[i]
		parts, err := bktRef.Arr.GetParts()
		if err != nil {
			return nil, errors.Wrapf(err, "Couldn't get partitions from input ref %v", i)
		}
		reader, err := parts[bktRef.PartIdx].GetRangeReader(bktRef.Start, bktRef.Start+bktRef.NByte)
		if err != nil {
			return nil, errors.Wrapf(err, "Couldn't read partition from ref %v", i)
		}

		err = binary.Read(reader, binary.LittleEndian, inInts[inPos:inPos+(bktRef.NByte/4)])
		if err != nil {
			return nil, errors.Wrapf(err, "Couldn't read from input ref %v", i)
		}
		inPos += bktRef.NByte / 4
		reader.Close()
	}

	// Actual Sort
	nBucket := 1 << width
	boundaries := make([]uint32, nBucket)
	if err := localSortPartial(inInts, boundaries, offset, width); err != nil {
		return nil, errors.Wrap(err, "Local sort failed")
	}

	// Write Outputs
	outArr, err := factory("output", nBucket)
	if err != nil {
		return nil, errors.Wrap(err, "Could not allocate output")
	}

	outParts, err := outArr.GetParts()
	if err != nil {
		return nil, errors.Wrap(err, "Output array failure")
	}

	for i := 0; i < nBucket; i++ {
		writer, err := outParts[i].GetWriter()
		if err != nil {
			return nil, errors.Wrapf(err, "Failed to write bucket %v", i)
		}

		start := (int)(boundaries[i])
		var end int
		if i == nBucket-1 {
			end = nInt
		} else {
			end = (int)(boundaries[i+1])
		}

		err = binary.Write(writer, binary.LittleEndian, inInts[start:end])
		if err != nil {
			writer.Close()
			return nil, errors.Wrap(err, "Could not write to output")
		}
		writer.Close()
	}
	return outArr, nil
}

// Iterate a list of arrays by bucket (every array's part 0 then every array's
// part 1). Implements io.Reader.
type BucketReader struct {
	arrs  []data.DistribArray
	parts [][]data.DistribPart
	arrX  int // Index of next array to read from
	partX int // Index of next partition (bucket) to read from
	dataX int // Index of next address within the partition to read from
	nArr  int // Number of arrays
	nPart int // Number of partitions (should be fixed for each array)
}

func NewBucketReader(sources []data.DistribArray) (*BucketReader, error) {
	var err error

	parts := make([][]data.DistribPart, len(sources))
	for i, arr := range sources {
		parts[i], err = arr.GetParts()
		if err != nil {
			return nil, err
		}
	}

	return &BucketReader{arrs: sources, parts: parts,
		arrX: 0, partX: 0,
		nArr: len(sources), nPart: len(parts[0]),
	}, nil
}

func (self *BucketReader) Read(out []byte) (n int, err error) {
	nNeeded := len(out)
	outX := 0
	for ; self.partX < self.nPart; self.partX++ {
		for ; self.arrX < self.nArr; self.arrX++ {
			part := self.parts[self.arrX][self.partX]
			partLen, err := part.Len()
			if err != nil {
				return 0, errors.Wrapf(err, "Couldn't determine length of input %v:%v", self.arrX, self.partX)
			}

			for self.dataX < partLen {
				reader, err := part.GetRangeReader(self.dataX, 0)
				if err != nil {
					return outX, errors.Wrapf(err, "Couldnt read input %v:%v", self.arrX, self.partX)
				}

				nRead, readErr := reader.Read(out[outX:])
				reader.Close()

				self.dataX += nRead
				nNeeded -= nRead
				outX += nRead

				if readErr != io.EOF && readErr != nil {
					return outX, errors.Wrapf(err, "Failed to read from partition %v:%v", self.arrX, self.partX)
				} else if nNeeded == 0 {
					// There is a corner case where nNeeded==0 and
					// readErr==io.EOF. In this case, the next call to
					// BucketReader.Read() will re-read the partition and
					// immediately get EOF again, which is fine (if slightly
					// inefficient)
					return outX, nil
				} else if err == io.EOF {
					break
				}
			}
			self.dataX = 0
		}
		self.arrX = 0
	}
	return outX, io.EOF
}

// Same as BucketReader but returns PartRef's instead of bytes (doesn't
// implement io.Reader but has similar behavior).
type BucketRefIterator struct {
	arrs  []data.DistribArray
	parts [][]data.DistribPart
	arrX  int // Index of next array to read from
	partX int // Index of next partition (bucket) to read from
	dataX int // Index of next address within the partition to read from
	nArr  int // Number of arrays
	nPart int // Number of partitions (should be fixed for each array)
}

func NewBucketRefIterator(source []data.DistribArray) (*BucketRefIterator, error) {
	var err error

	parts := make([][]data.DistribPart, len(source))
	for i, arr := range source {
		parts[i], err = arr.GetParts()
		if err != nil {
			return nil, err
		}
	}

	return &BucketRefIterator{arrs: source, parts: parts,
		arrX: 0, partX: 0,
		nArr: len(source), nPart: len(parts[0]),
	}, nil
}

// Return the next group of PartReferences to cover sz bytes. If there is no
// more data, returns io.EOF. The returned PartRefs may not contain sz bytes in
// this case.
func (self *BucketRefIterator) Next(sz int) ([]*data.PartRef, error) {
	var out []*data.PartRef

	nNeeded := sz
	for ; self.partX < self.nPart; self.partX++ {
		for ; self.arrX < self.nArr; self.arrX++ {
			part := self.parts[self.arrX][self.partX]
			partLen, err := part.Len()
			if err != nil {
				return nil, errors.Wrapf(err, "Couldn't determine length of input %v:%v", self.arrX, self.partX)
			}

			for self.dataX < partLen {
				nRemaining := partLen - self.dataX

				var toWrite int
				if nRemaining <= nNeeded {
					toWrite = nRemaining
				} else {
					toWrite = nNeeded
				}
				out = append(out, &data.PartRef{Arr: self.arrs[self.arrX], PartIdx: self.partX, Start: self.dataX, NByte: toWrite})
				self.dataX += toWrite
				nNeeded -= toWrite

				if nNeeded == 0 {
					return out, nil
				}
			}
			self.dataX = 0
		}
		self.arrX = 0
	}
	return out, io.EOF
}

// Distributed sort of arr. The bytes in arr will be interpreted as uint32's
// Returns an ordered list of distributed arrays containing the sorted output
// (concatenate each array's partitions in order to get final result). 'len' is
// the number of uint32's in arr.
func SortDistrib(arr data.DistribArray, len int,
	factory ArrayFactory, worker DistribWorker) ([]data.DistribArray, error) {
	// Data Layout:
	//	 - Distrib Arrays store all output from a single node
	//	 - DistribParts represent radix sort buckets (there will be nbucket parts per DistribArray)
	//
	// Basic algorithm/schema:
	//   - Inputs: each worker recieves as input a reference to the
	//     DistribParts it should consume. The first partition may include an
	//     offset to start reading from. Likewise, the last partition may include
	//     an offest to stop reading at. Intermediate partitions are read in
	//     their entirety.
	//	 - Outputs: Each worker will output a DistribArray with one partition
	//	   per radix bucket. Partitions may have zero length, but they will
	//	   always exist.
	//	 - Input distribArrays may be garbage collected after every worker has
	//     provided their output (output distribArrays are copies, not references).
	nworker := 2          //number of workers (degree of parallelism)
	width := 4            //number of bits to sort per round
	nstep := (32 / width) // number of steps needed to fully sort

	// Target number of uint32s to process per worker, the last worker might get less
	maxPerWorker := (int)(math.Ceil((float64)(len) / (float64)(nworker)))

	// Initial input is the output for "step -1"
	var outputs []data.DistribArray
	outputs = []data.DistribArray{arr}

	for step := 0; step < nstep; step++ {
		inputs := outputs
		outputs = make([]data.DistribArray, nworker)

		inGen, err := NewBucketRefIterator(inputs)
		if err != nil {
			return nil, err
		}

		var wg sync.WaitGroup
		wg.Add(nworker)
		errChan := make(chan error, nworker)
		for workerId := 0; workerId < nworker; workerId++ {
			// Repartition previous output
			workerInputs, genErr := inGen.Next(maxPerWorker * 4)
			if genErr == io.EOF && workerId+1 != nworker {
				return nil, errors.New("Premature EOF from input generator")
			} else if err != nil && err != io.EOF {
				return nil, errors.Wrap(err, "Input generator had an error")
			}

			go func(id int, inputs []*data.PartRef) {
				defer wg.Done()

				workerFactory := func(name string, nbucket int) (data.DistribArray, error) {
					return factory(
						fmt.Sprintf("step%v.worker%v.%v", step, id, name),
						nbucket)
				}

				outputs[id], err = worker(inputs, step*width, width,
					workerFactory)

				if err != nil {
					fmt.Println("Got Error")
					errChan <- errors.Wrapf(err, "Worker failure on step %v, worker %v", step, id)
					return
				}
			}(workerId, workerInputs)
		}
		wg.Wait()
		select {
		case firstErr := <-errChan:
			return nil, errors.Wrapf(firstErr, "Worker failure")
		default:
		}

	}
	return outputs, nil
}
