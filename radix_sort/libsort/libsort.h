//
// Created by Nathan Pemberton on 6/4/20.
//

#ifndef LIBSORT_LIBSORT_H
#define LIBSORT_LIBSORT_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
// Perform a partial sort of bits [offset, width). boundaries will contain the
// index of the first element of each unique group value (each unique value of
// width bits), it must be 2^width elements long.
extern "C" bool gpuPartial(uint32_t* h_in, uint32_t *boundaries, size_t h_in_len, uint32_t offset, uint32_t width);

// Sort host-provided input (h_in) in-place using the GPU
extern "C" bool providedGpu(unsigned int* h_in, size_t len);

// Sort provided input (in) using the CPU
extern "C" bool providedCpu(unsigned int* in, size_t len);
#else
bool gpuPartial(uint32_t* h_in, uint32_t *boundaries, size_t h_in_len, uint32_t offset, uint32_t width);
bool providedGpu(unsigned int* h_in, size_t len);
bool providedCpu(unsigned int* in, size_t len);
#endif //__cplusplus

#endif //LIBSORT_LIBSORT_H
