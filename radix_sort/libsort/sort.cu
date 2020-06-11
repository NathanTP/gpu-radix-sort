#include "sort.h"
#include <stdio.h>
#include <string.h>

#define MAX_BLOCK_SZ 128

__global__ void gpu_radix_sort_local(unsigned int* d_out_sorted,
    unsigned int* d_prefix_sums,
    unsigned int* d_block_sums,
    unsigned int input_shift_width,
    unsigned int* d_in,
    unsigned int d_in_len,
    unsigned int max_elems_per_block)
{
    // need shared memory array for:
    // - block's share of the input data (local sort will be put here too)
    // - mask outputs
    // - scanned mask outputs
    // - merged scaned mask outputs ("local prefix sum")
    // - local sums of scanned mask outputs
    // - scanned local sums of scanned mask outputs

    // for all radix combinations:
    //  build mask output for current radix combination
    //  scan mask ouput
    //  store needed value from current prefix sum array to merged prefix sum array
    //  store total sum of mask output (obtained from scan) to global block sum array
    // calculate local sorted address from local prefix sum and scanned mask output's total sums
    // shuffle input block according to calculated local sorted addresses
    // shuffle local prefix sums according to calculated local sorted addresses
    // copy locally sorted array back to global memory
    // copy local prefix sum array back to global memory

    extern __shared__ unsigned int shmem[];
    unsigned int* s_data = shmem;
    // s_mask_out[] will be scanned in place
    unsigned int s_mask_out_len = max_elems_per_block + 1;
    unsigned int* s_mask_out = &s_data[max_elems_per_block];
    // 2bit-specific prefix-sum for each elem (e.g. where in the 2bit's output block this elem should go)
    unsigned int* s_merged_scan_mask_out = &s_mask_out[s_mask_out_len];
    // per-block per-2bit count (how many elems of each 2bit there are)
    unsigned int* s_mask_out_sums = &s_merged_scan_mask_out[max_elems_per_block];
    // per-block starting point for each 2bit
    unsigned int* s_scan_mask_out_sums = &s_mask_out_sums[4];

    unsigned int thid = threadIdx.x;

    // Copy block's portion of global input data to shared memory
    unsigned int cpy_idx = max_elems_per_block * blockIdx.x + thid;
    if (cpy_idx < d_in_len)
        s_data[thid] = d_in[cpy_idx];
    else
        s_data[thid] = 0;

    __syncthreads();

    // To extract the correct 2 bits, we first shift the number
    //  to the right until the correct 2 bits are in the 2 LSBs,
    //  then mask on the number with 11 (3) to remove the bits
    //  on the left
    unsigned int t_data = s_data[thid];
    unsigned int t_2bit_extract = (t_data >> input_shift_width) & 3;

    for (unsigned int i = 0; i < 4; ++i)
    {
        // Zero out s_mask_out
        s_mask_out[thid] = 0;
        if (thid == 0)
            s_mask_out[s_mask_out_len - 1] = 0;

        __syncthreads();

        // build bit mask output
        bool val_equals_i = false;
        if (cpy_idx < d_in_len)
        {
            val_equals_i = t_2bit_extract == i;
            s_mask_out[thid] = val_equals_i;
        }
        __syncthreads();

        // Scan mask outputs (Hillis-Steele)
        int partner = 0;
        unsigned int sum = 0;
        unsigned int max_steps = (unsigned int) log2f(max_elems_per_block);
        for (unsigned int d = 0; d < max_steps; d++) {
            partner = thid - (1 << d);
            if (partner >= 0) {
                sum = s_mask_out[thid] + s_mask_out[partner];
            }
            else {
                sum = s_mask_out[thid];
            }
            __syncthreads();
            s_mask_out[thid] = sum;
            __syncthreads();
        }

        // Shift elements to produce the same effect as exclusive scan
        unsigned int cpy_val = 0;
        cpy_val = s_mask_out[thid];
        __syncthreads();
        s_mask_out[thid + 1] = cpy_val;
        __syncthreads();

        if (thid == 0)
        {
            // Zero out first element to produce the same effect as exclusive scan
            s_mask_out[0] = 0;
            unsigned int total_sum = s_mask_out[s_mask_out_len - 1];
            s_mask_out_sums[i] = total_sum;
            d_block_sums[i * gridDim.x + blockIdx.x] = total_sum;
        }
        __syncthreads();

        if (val_equals_i && (cpy_idx < d_in_len))
        {
            s_merged_scan_mask_out[thid] = s_mask_out[thid];
        }

        __syncthreads();
    }

    // Scan mask output sums
    // Just do a naive scan since the array is really small
    if (thid == 0)
    {
        unsigned int run_sum = 0;
        for (unsigned int i = 0; i < 4; ++i)
        {
            s_scan_mask_out_sums[i] = run_sum;
            run_sum += s_mask_out_sums[i];
        }
    }

    __syncthreads();

    if (cpy_idx < d_in_len)
    {
        // Calculate the new indices of the input elements for sorting
        unsigned int t_prefix_sum = s_merged_scan_mask_out[thid];
        unsigned int new_pos = t_prefix_sum + s_scan_mask_out_sums[t_2bit_extract];
        
        __syncthreads();

        // Shuffle the block's input elements to actually sort them
        // Do this step for greater global memory transfer coalescing
        //  in next step
        s_data[new_pos] = t_data;
        s_merged_scan_mask_out[new_pos] = t_prefix_sum;
        
        __syncthreads();

        // Copy block - wise prefix sum results to global memory
        // Copy block-wise sort results to global 
        d_prefix_sums[cpy_idx] = s_merged_scan_mask_out[thid];
        d_out_sorted[cpy_idx] = s_data[thid];
    }
    //XXX d_out_sorted is sorted per block
    //XXX d_prefix_sums is the per-block, per-bit prefix sums
    //XXX s_scan_mask_out_sums has the per-block starting index of each 2bit. It is stored in d_block_sums.
}

__global__ void gpu_glbl_shuffle(unsigned int* d_out,
    unsigned int* d_in,
    unsigned int* d_scan_block_sums,
    unsigned int* d_prefix_sums,
    unsigned int input_shift_width,
    unsigned int d_in_len,
    unsigned int max_elems_per_block)
{
    // get d = digit
    // get n = blockIdx
    // get m = local prefix sum array value
    // calculate global position = P_d[n] + m
    // copy input element to final position in d_out

    unsigned int thid = threadIdx.x;
    unsigned int cpy_idx = max_elems_per_block * blockIdx.x + thid;

    if (cpy_idx < d_in_len)
    {
        unsigned int t_data = d_in[cpy_idx];
        unsigned int t_2bit_extract = (t_data >> input_shift_width) & 3;
        unsigned int t_prefix_sum = d_prefix_sums[cpy_idx];
        unsigned int data_glbl_pos = d_scan_block_sums[t_2bit_extract * gridDim.x + blockIdx.x]
            + t_prefix_sum;
        __syncthreads();
        d_out[data_glbl_pos] = t_data;
    }
}

bool check(unsigned int* d_in, unsigned int* d_prefix_sums, unsigned int len, int shift_width)
{
    int nprefix = (1 << (shift_width + 2));
    unsigned int *h_dat = new unsigned int[len];
    unsigned int *h_prefix_sums = new unsigned int[len];
    unsigned int *prefix_boundaries = new unsigned int[nprefix];
    cudaMemcpy(h_dat, d_in, sizeof(unsigned int)*len, cudaMemcpyDeviceToHost);
    cudaMemcpy(h_prefix_sums, d_prefix_sums, sizeof(unsigned int)*len, cudaMemcpyDeviceToHost);

    unsigned int old_prefix = 0;
    prefix_boundaries[0] = 0;
    bool success = true;
    int nchange = 0;

    for(unsigned int i = 0; i < len; i++) {
        // Grab total prefix sorted so far
        unsigned int prefix = h_dat[i] & (nprefix - 1);
        if(prefix < old_prefix) {
            printf("prefix changed from %d to %d at %d\n", old_prefix, prefix, i);
            std::cout << "Prefixes not increasing monotonically!\n";
            success = false;
            break;
        }
        if(prefix != old_prefix) {
            nchange++;
            if(prefix > (unsigned int)(nprefix - 1)) {
                printf("Prefix (%d) out of range (expected < %d prefixes)\n", prefix, nprefix);
                break;
            }
            prefix_boundaries[prefix] = i;
        }
        old_prefix = prefix;
    }
    printf("nchange=%d\n", nchange);
    if(success) {
        for (int i = 0; i < nprefix; i++) {
            printf("Prefix %d at %u\n", i, prefix_boundaries[i]);
        }
    }
//    printf("Prefix sums:\n");
//    for(unsigned int i = 0; i < len; i++) {
//        printf("%u:\t%u\t(%x)\n", i, h_prefix_sums[i], h_dat[i]);
//    }
    delete[] h_dat;
    delete[] prefix_boundaries;
    return success;
}

// Allocate all intermediate state needed to perform a sort of d_in into d_out
sort_state_t *create_state(unsigned int* const d_out,
    unsigned int* const d_in,
    unsigned int d_in_len)
{
    sort_state_t *state = (sort_state_t*)malloc(sizeof(sort_state_t));
    state->d_out = d_out;
    state->d_in = d_in;
    state->data_len = d_in_len;

    state->block_sz = MAX_BLOCK_SZ;
    state->grid_sz = state->data_len / state->block_sz;

    // Take advantage of the fact that integer division drops the decimals
    if (state->data_len % state->block_sz != 0)
        state->grid_sz += 1;

    // The per-block, per-bit prefix sums (where this value goes in the per-block 2bit group)
    state->prefix_sums_len = state->data_len;
    checkCudaErrors(cudaMalloc(&(state->d_prefix_sums), sizeof(unsigned int) * state->prefix_sums_len));
    checkCudaErrors(cudaMemset(state->d_prefix_sums, 0, sizeof(unsigned int) * state->prefix_sums_len));

    // per-block starting index (count) of each 2bit grouped by 2bit (d_block_sums[0-nblock] are all the 0 2bits)
    // e.g. 4 indices per block
    state->block_sums_len = 4 * state->grid_sz;
    checkCudaErrors(cudaMalloc(&(state->d_block_sums), sizeof(unsigned int) * state->block_sums_len));
    checkCudaErrors(cudaMemset(state->d_block_sums, 0, sizeof(unsigned int) * state->block_sums_len));

    // prefix-sum of d_block_sums, e.g. the starting position for each block's 2bit group
    // (d_scan_block_sums[1] is where block 1's 2bit group 0 should start)
    state->scan_block_sums_len = state->block_sums_len;
    checkCudaErrors(cudaMalloc(&(state->d_scan_block_sums), sizeof(unsigned int) * state->block_sums_len));
    checkCudaErrors(cudaMemset(state->d_scan_block_sums, 0, sizeof(unsigned int) * state->block_sums_len));

    // shared memory consists of 3 arrays the size of the block-wise input
    //  and 2 arrays the size of n in the current n-way split (4)
    unsigned int s_data_len = state->block_sz;
    unsigned int s_mask_out_len = state->block_sz + 1;
    unsigned int s_merged_scan_mask_out_len = state->block_sz;
    unsigned int s_mask_out_sums_len = 4; // 4-way split
    unsigned int s_scan_mask_out_sums_len = 4;
    state->shmem_sz = (s_data_len 
                            + s_mask_out_len
                            + s_merged_scan_mask_out_len
                            + s_mask_out_sums_len
                            + s_scan_mask_out_sums_len)
                            * sizeof(unsigned int);

    return state;
}

// Destroy's everything allocated by init_sort(). It is invalid to use state
// after calling destroy_state(state). Noteably, this does not deallocate
// state->d_in or d_out, you must free those independently.
void destroy_state(sort_state_t *state)
{
    checkCudaErrors(cudaFree(state->d_scan_block_sums));
    checkCudaErrors(cudaFree(state->d_block_sums));
    checkCudaErrors(cudaFree(state->d_prefix_sums));
    free(state);
}

// An attempt at the gpu radix sort variant described in this paper:
// https://vgc.poly.edu/~csilva/papers/cgf.pdf
void radix_sort(unsigned int* const d_out,
    unsigned int* const d_in,
    unsigned int d_in_len)
{
    /* unsigned int block_sz = MAX_BLOCK_SZ; */
    /* unsigned int max_elems_per_block = block_sz; */
    /* unsigned int grid_sz = d_in_len / max_elems_per_block; */
    /*  */
    /* // Take advantage of the fact that integer division drops the decimals */
    /* if (d_in_len % max_elems_per_block != 0) */
    /*     grid_sz += 1; */
    /*  */
    /* // The per-block, per-bit prefix sums (where this value goes in the per-block 2bit group) */
    /* unsigned int* d_prefix_sums; */
    /* unsigned int d_prefix_sums_len = d_in_len; */
    /* checkCudaErrors(cudaMalloc(&d_prefix_sums, sizeof(unsigned int) * d_prefix_sums_len)); */
    /* checkCudaErrors(cudaMemset(d_prefix_sums, 0, sizeof(unsigned int) * d_prefix_sums_len)); */
    /*  */
    /* // per-block starting index (count) of each 2bit grouped by 2bit (d_block_sums[0-nblock] are all the 0 2bits) */
    /* unsigned int* d_block_sums; */
    /* unsigned int d_block_sums_len = 4 * grid_sz; // 4-way split */
    /* checkCudaErrors(cudaMalloc(&d_block_sums, sizeof(unsigned int) * d_block_sums_len)); */
    /* checkCudaErrors(cudaMemset(d_block_sums, 0, sizeof(unsigned int) * d_block_sums_len)); */
    /*  */
    /* // prefix-sum of d_block_sums, e.g. the starting position for each block's 2bit group */
    /* // (d_scan_block_sums[1] is where block 1's 2bit group 0 should start) */
    /* unsigned int* d_scan_block_sums; */
    /* checkCudaErrors(cudaMalloc(&d_scan_block_sums, sizeof(unsigned int) * d_block_sums_len)); */
    /* checkCudaErrors(cudaMemset(d_scan_block_sums, 0, sizeof(unsigned int) * d_block_sums_len)); */
    /*  */
    /* // shared memory consists of 3 arrays the size of the block-wise input */
    /* //  and 2 arrays the size of n in the current n-way split (4) */
    /* unsigned int s_data_len = max_elems_per_block; */
    /* unsigned int s_mask_out_len = max_elems_per_block + 1; */
    /* unsigned int s_merged_scan_mask_out_len = max_elems_per_block; */
    /* unsigned int s_mask_out_sums_len = 4; // 4-way split */
    /* unsigned int s_scan_mask_out_sums_len = 4; */
    /* unsigned int shmem_sz = (s_data_len  */
    /*                         + s_mask_out_len */
    /*                         + s_merged_scan_mask_out_len */
    /*                         + s_mask_out_sums_len */
    /*                         + s_scan_mask_out_sums_len) */
    /*                         * sizeof(unsigned int); */


    sort_state_t *state = create_state(d_out, d_in, d_in_len);

    // for every 2 bits from LSB to MSB:
    //  block-wise radix sort (write blocks back to global memory)
    for (unsigned int shift_width = 0; shift_width <= 30; shift_width += 2)
    {
        // per-block sort. Also creates blockwise prefix sums.
        gpu_radix_sort_local<<<state->grid_sz, state->block_sz, state->shmem_sz>>>(state->d_out, 
                                                                state->d_prefix_sums, 
                                                                state->d_block_sums, 
                                                                shift_width, 
                                                                state->d_in, 
                                                                state->data_len, 
                                                                state->block_sz);

        // create global prefix sum arrays
        sum_scan_blelloch(state->d_scan_block_sums, state->d_block_sums, state->block_sums_len);

        // scatter/shuffle block-wise sorted array to final positions
        gpu_glbl_shuffle<<<state->grid_sz, state->block_sz>>>(state->d_in, 
                                                    state->d_out, 
                                                    state->d_scan_block_sums, 
                                                    state->d_prefix_sums, 
                                                    shift_width, 
                                                    state->data_len, 
                                                    state->block_sz);
    }

    checkCudaErrors(cudaMemcpy(state->d_out, state->d_in, sizeof(unsigned int) * state->data_len, cudaMemcpyDeviceToDevice));

    destroy_state(state);
    /* checkCudaErrors(cudaFree(d_scan_block_sums)); */
    /* checkCudaErrors(cudaFree(d_block_sums)); */
    /* checkCudaErrors(cudaFree(d_prefix_sums)); */
}
